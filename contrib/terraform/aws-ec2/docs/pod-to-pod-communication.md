# Pod-to-pod communication across nodes

This document explains in full detail every step a network packet takes when
travelling from a pod on the server node to a pod on the agent node. Each step
identifies the component responsible, what it does, and why it is necessary.

The example uses the following addresses throughout:

```
Server node:   10.0.1.10   (EC2 private IP)
Agent node:    10.0.1.20   (EC2 private IP)

Pod A:         10.42.0.2   (running on server node)
Pod B:         10.42.1.2   (running on agent node)
```

---

## Full journey overview

```
SERVER NODE (10.0.1.10)                        AGENT NODE (10.0.1.20)
────────────────────────────────               ────────────────────────────────
Pod A network namespace                        Pod B network namespace
┌──────────────┐                              ┌──────────────┐
│ eth0         │                              │ eth0         │
│ 10.42.0.2    │                              │ 10.42.1.2    │
└──────┬───────┘                              └──────▲───────┘
       │ virtual ethernet pair                       │ virtual ethernet pair
───────┼─── host network namespace ──────── ─────────┼─── host network namespace ──
       │                                             │
┌──────▼───────┐  Step 1: eBPF program       ┌──────┴───────┐  Step 7: eBPF program
│ lxcAAAA      │    connection tracking       │ lxcBBBB      │    connection tracking
└──────┬───────┘    policy check              └──────▲───────┘    policy check
       │                                             │
       │  Step 2: kernel routing table               │  Step 6: bpf_redirect()
       │  10.42.1.0/24 via 10.0.1.20                │  Cilium endpoint map lookup
       │                                             │  10.42.1.2 → lxcBBBB
       │                                             │
┌──────▼───────┐  Step 3: ARP resolution     ┌──────┴───────┐
│ eth0         │    Ethernet frame built      │ eth0         │
│ 10.0.1.10    ├────────────────────────────►│ 10.0.1.20    │
└──────────────┘  Step 4: AWS network fabric  └──────────────┘
                  destination MAC = agent ✓
                  source/destination check
                  disabled on both nodes ✓
                           │
                   Step 5: packet arrives
                   at agent eth0
```

---

## Step 1 — Pod A sends a packet: Cilium extended Berkeley Packet Filter program on the host-side virtual ethernet interface

### 1.1 Linux network namespaces — why a pod has its own network stack

Every pod runs inside a dedicated **Linux network namespace**. A network
namespace is a fully isolated copy of the Linux network stack: it has its own
set of network interfaces, its own routing table, its own netfilter rules, and
its own connection tracking table. Processes running inside a namespace can only
see the interfaces that belong to it.

When k3s starts a pod, the container runtime creates a new network namespace for
that pod and places a virtual network interface named `eth0` inside it. From the
point of view of any process in the pod, this `eth0` is the only network card
that exists. It carries the pod IP address, in this case `10.42.0.2`.

```
┌──────────────────────────────────────────────────┐
│  Pod A — isolated Linux network namespace        │
│                                                  │
│  Interface: eth0                                 │
│  Address:   10.42.0.2 / 24                       │
│  Route:     default via 10.42.0.1                │
│                                                  │
│  Processes here see nothing outside              │
│  this namespace.                                 │
└──────────────────────────────────────────────────┘
```

### 1.2 The virtual ethernet pair — connecting the pod namespace to the host namespace

A **virtual ethernet pair** is a pair of virtual network interfaces linked
together by the kernel at creation time. They behave exactly like a physical
cable between two network cards: anything written into one end appears
immediately on the other end, with no copying.

Cilium creates one virtual ethernet pair per pod:

- One end, named `eth0`, is placed inside the pod network namespace. This is
  the interface the pod processes use.
- The other end, named `lxcAAAA`, stays in the host network namespace — the
  root namespace that has access to the physical network interface of the node.

```
┌──────────────────────────────────────────────────────┐
│  Pod A — isolated network namespace                  │
│  ┌──────────────────┐                                │
│  │ eth0 (10.42.0.2) │  ← pod process writes here    │
│  └────────┬─────────┘                                │
└───────────┼──────────────────────────────────────────┘
            │ virtual ethernet pair (bidirectional pipe)
┌───────────┼──────────────────────────────────────────┐
│  Host network namespace         │                    │
│  ┌────────▼─────────┐           │                    │
│  │ lxcAAAA          │  ← packet appears here         │
│  │ (no IP assigned) │                                │
│  └──────────────────┘                                │
│                                                      │
│  eth0 (10.0.1.10)  ← physical network interface      │
└──────────────────────────────────────────────────────┘
```

The host-side interface `lxcAAAA` has no IP address. It exists solely as the
attachment point for the Cilium extended Berkeley Packet Filter program.

### 1.3 The traffic control framework — where the extended Berkeley Packet Filter program attaches

The Linux kernel includes a subsystem called **traffic control**. It provides
hooks at specific points in the packet processing pipeline where a program can
be attached to inspect or modify every packet that passes through.

The two hooks that matter here are:

- **Ingress hook** — runs on every packet arriving at an interface, before the
  kernel routing subsystem processes it.
- **Egress hook** — runs on every packet about to leave an interface, after
  routing has decided where to send it.

Cilium attaches an extended Berkeley Packet Filter program to the **ingress hook
of `lxcAAAA`**. Because packets written by the pod into its `eth0` appear at
`lxcAAAA`, this means Cilium intercepts every outgoing pod packet before the
kernel routing table, before netfilter, and before any iptables rule.

```
Pod A writes packet to eth0
          │
          │ virtual ethernet pair
          ▼
lxcAAAA — traffic control ingress hook
          │
          ▼
┌──────────────────────────────────────────────────┐
│  Cilium extended Berkeley Packet Filter program  │
│                                                  │
│  Runs in kernel space — no context switch.       │
│  Has read/write access to the packet.            │
│  Can drop, modify, redirect, or pass it.         │
│                                                  │
│  Executes before kernel routing.                 │
│  Executes before iptables and netfilter.         │
└──────────────────────────────────────────────────┘
          │
          ▼  (if the program passes the packet)
   Linux kernel routing subsystem
```

### 1.4 Connection tracking — recording the new flow

The first thing the program does is search the **connection tracking table** for
an entry matching this packet. The connection tracking table is a hash table
stored in kernel memory (implemented as a Berkeley Packet Filter map in Cilium's
case). Each entry records:

- source IP address and port
- destination IP address and port
- protocol
- connection state (new, established, closing)
- a timestamp used to expire entries that have been idle too long

For this packet (source `10.42.0.2`, destination `10.42.1.2`), no entry exists
yet. The program creates one:

```
Source:       10.42.0.2
Destination:  10.42.1.2
Protocol:     TCP / UDP / ICMP
State:        new
Direction:    egress
```

This entry serves two purposes going forward:

1. **Return traffic**: when pod B replies, the connection tracking entry on the
   agent node allows that reply to be recognised as belonging to an existing
   connection rather than being treated as a new unsolicited packet. Policy
   evaluation for established connections is a fast path.
2. **Subsequent packets**: further packets in the same connection hit the
   existing entry and skip the full policy evaluation, reducing per-packet cost.

### 1.5 Network policy enforcement — is this connection permitted?

The program then evaluates the **network policy** rules that apply to pod A.
Cilium translates Kubernetes NetworkPolicy objects (and its own
CiliumNetworkPolicy objects) into entries in Berkeley Packet Filter maps when
those policies are created or updated in the cluster. At packet time the program
only performs a hash table lookup — it does not parse policy files or contact
the API server.

The lookup key is the security identity of pod A (derived from its Kubernetes
labels) combined with the security identity of the destination and the port and
protocol:

```
Source identity:      pod A labels, e.g. app=frontend
Destination identity: pod B labels, e.g. app=backend
Port and protocol:    80 / TCP

Result: ALLOW  →  packet continues
        DROP   →  packet discarded, counter incremented
```

If no NetworkPolicy objects exist in the cluster (which is the default state),
Cilium allows all traffic and this check always passes immediately.

### 1.6 Destination type — deciding whether address translation is needed

The last check the program performs is determining what kind of address the
destination `10.42.1.2` is:

- **Pod IP address** (within the cluster pod CIDR `10.42.0.0/16`) — the address
  is real and directly routable. No translation is needed. The packet is passed
  unchanged to the kernel routing subsystem.
- **Service ClusterIP address** (within the service CIDR `10.43.0.0/16`) — this
  is a virtual address that has no real network interface behind it. The program
  would rewrite the destination to one of the backing pod IP addresses
  (destination network address translation). This is how Cilium replaces
  kube-proxy for service load balancing. This case does not apply here.

Since `10.42.1.2` is a pod IP address, the program passes the packet unchanged.

---

## Step 2 — Kernel routing table: route installed by Cilium `autoDirectNodeRoutes`

The packet enters the Linux kernel routing subsystem in the host network
namespace. The kernel looks up the destination address `10.42.1.2` in the
routing table:

```
Destination        Next hop          Interface
10.42.0.0/24       local             cilium_host     ← server node's own pods
10.42.1.0/24       10.0.1.20         eth0            ← agent node's pods
```

The second route was not configured manually. Cilium's control plane watches the
Kubernetes Node objects through the API server. When the agent node registered
itself and the Kubernetes node controller wrote `spec.podCIDR = 10.42.1.0/24`
into that Node object, Cilium on the server node called the Linux routing
subsystem to add the route `10.42.1.0/24 via 10.0.1.20 dev eth0`. This is
what `autoDirectNodeRoutes = true` in the Helm chart enables.

The kernel resolves the result: to reach `10.42.1.2`, send the packet to the
next hop `10.0.1.20` through interface `eth0`.

---

## Step 3 — Address Resolution Protocol: resolving the MAC address of the next hop

The kernel has determined that the next hop is `10.0.1.20`, but transmitting an
Ethernet frame requires a **hardware MAC address**, not an IP address. The kernel
either finds `10.0.1.20` already cached in its Address Resolution Protocol table
from a previous lookup, or it sends a broadcast frame on the subnet asking "who
has IP address `10.0.1.20`?". The agent node's kernel responds with the MAC
address of its `eth0` interface.

The kernel then builds the outgoing Ethernet frame:

```
Ethernet header:
  Source MAC:      server eth0 MAC address
  Destination MAC: agent eth0 MAC address

IP header:
  Source IP:       10.42.0.2   ← pod A address
  Destination IP:  10.42.1.2   ← pod B address
```

The IP addresses in the packet are pod addresses, not node addresses. The
Ethernet layer uses MAC addresses to carry the frame to the correct physical
host within the subnet. The AWS network fabric does not need a routing table
entry for the pod address ranges — it uses the destination MAC address to find
the right network interface card.

---

## Step 4 — AWS network fabric: delivery within the subnet and source/destination check

The Ethernet frame leaves the server node's `eth0` and enters the AWS virtual
network fabric. Because both nodes are in the same subnet (`10.0.1.0/24`),
delivery is a Layer 2 operation: the fabric looks at the destination MAC address
and delivers the frame to the network interface card on the agent node that owns
that MAC address.

Without any special configuration, AWS performs two security checks on every
frame passing through a network interface card:

- **Source check**: is the source IP address (`10.42.0.2`) assigned to the
  sending network interface card? The answer is no — the card is assigned
  `10.0.1.10`. AWS would drop the frame.
- **Destination check**: is the destination IP address (`10.42.1.2`) assigned
  to the receiving network interface card? The answer is no — the card is
  assigned `10.0.1.20`. AWS would drop the frame.

Both of these checks are disabled by `source_dest_check = false` on both EC2
instances in the Terraform configuration. With the checks disabled, the AWS
network fabric forwards the frame based solely on the destination MAC address
and ignores whether the IP addresses belong to the respective network interface
cards.

---

## Step 5 — Packet arrives at the agent node

The agent node's network interface card receives the Ethernet frame and passes
it to the Linux kernel of the agent node. The kernel sees an IP packet with:

```
Source IP:       10.42.0.2
Destination IP:  10.42.1.2
```

Neither of these is the node's own IP address. Without Cilium, the kernel would
have no local route for `10.42.1.2` and would drop the packet or try to forward
it elsewhere. Cilium's extended Berkeley Packet Filter program on this interface
intercepts the packet before the kernel routing subsystem runs, as described in
the next step.

---

## Step 6 — Cilium extended Berkeley Packet Filter program on the agent `eth0` traffic control ingress hook: endpoint redirect

Cilium attaches an extended Berkeley Packet Filter program to the **traffic
control ingress hook of the host `eth0` interface** on every node. This program
runs on every packet arriving at the physical interface before the kernel routing
subsystem processes it.

### 6.1 Endpoint map lookup

The program looks up the destination address `10.42.1.2` in the **Cilium
endpoint map** — a hash table in kernel memory that maps every pod IP address
local to this node to the index number of that pod's host-side virtual ethernet
interface:

```
Endpoint map (agent node):
  10.42.1.2  →  interface index of lxcBBBB
  10.42.1.3  →  interface index of lxcCCCC
  ...
```

The lookup for `10.42.1.2` returns the interface index of `lxcBBBB`.

### 6.2 Direct redirect — bypassing kernel routing

The program calls `bpf_redirect(lxcBBBB)`, a kernel function that injects the
packet directly into the `lxcBBBB` interface. This bypasses the kernel routing
subsystem, netfilter, and any iptables chains entirely for this last delivery
step. The packet is placed directly at the ingress hook of `lxcBBBB` without
going through any additional processing layers.

```
Packet arrives at agent eth0
          │
          ▼
traffic control ingress hook
          │
          ▼
┌──────────────────────────────────────────────────┐
│  Cilium extended Berkeley Packet Filter program  │
│                                                  │
│  Endpoint map lookup: 10.42.1.2 → lxcBBBB       │
│                                                  │
│  bpf_redirect(lxcBBBB)                          │
│  ↳ packet injected directly into lxcBBBB        │
│  ↳ kernel routing table: skipped                │
│  ↳ netfilter / iptables:  skipped                │
└──────────────────────────────────────────────────┘
```

---

## Step 7 — Cilium extended Berkeley Packet Filter program on `lxcBBBB`: policy enforcement on the receiving side

The packet arrives at `lxcBBBB`, the host-side end of pod B's virtual ethernet
pair. A Cilium extended Berkeley Packet Filter program attached to the traffic
control ingress hook of `lxcBBBB` runs:

### 7.1 Connection tracking — recording the flow on the receiving side

The program looks up the packet in the connection tracking table on the agent
node. It finds no existing entry for this flow in the ingress direction and
creates one, recording that this packet is an incoming new connection to pod B.
Subsequent packets in the same connection will be fast-pathed.

### 7.2 Network policy enforcement — ingress rules for pod B

The program evaluates the **ingress network policy** rules for pod B. The lookup
key is the identity of the source (pod A's labels) combined with the destination
identity (pod B's labels) and port and protocol:

```
Source identity:      pod A labels, e.g. app=frontend
Destination identity: pod B labels, e.g. app=backend
Port and protocol:    80 / TCP

Result: ALLOW  →  packet continues into pod B
        DROP   →  packet discarded before reaching pod B
```

### 7.3 Delivery into pod B

If the policy check passes, the packet crosses the virtual ethernet pair from
`lxcBBBB` into pod B's network namespace and arrives at pod B's `eth0` with:

```
Source IP:       10.42.0.2   ← preserved, unchanged throughout the journey
Destination IP:  10.42.1.2
```

Pod B's process reads the packet from its socket as if pod A had sent it
directly.

---

## Responsibility summary

| Step | Component responsible | What it does |
|---|---|---|
| 1.1 | Container runtime | Creates isolated network namespace for pod A |
| 1.2 | Cilium | Creates virtual ethernet pair connecting pod namespace to host namespace |
| 1.3 | Linux traffic control | Provides the ingress hook where the eBPF program attaches |
| 1.4 | Cilium eBPF program on `lxcAAAA` | Creates connection tracking entry for the new flow |
| 1.5 | Cilium eBPF program on `lxcAAAA` | Enforces egress network policy for pod A |
| 1.6 | Cilium eBPF program on `lxcAAAA` | Determines no address translation is needed |
| 2   | Linux kernel routing table | Resolves next hop to `10.0.1.20 dev eth0` |
| 2   | Cilium control plane (`autoDirectNodeRoutes`) | Installed that route by watching Kubernetes Node objects |
| 3   | Linux Address Resolution Protocol | Resolves MAC address of `10.0.1.20` |
| 4   | AWS network fabric | Delivers the Ethernet frame to the agent node using the destination MAC |
| 4   | `source_dest_check = false` on both EC2 instances | Prevents AWS from dropping frames with pod IP addresses |
| 5   | Linux kernel on agent node | Receives the Ethernet frame and passes it up the stack |
| 6.1 | Cilium eBPF program on agent `eth0` | Looks up `10.42.1.2` in the endpoint map, finds `lxcBBBB` |
| 6.2 | Cilium eBPF program on agent `eth0` | Calls `bpf_redirect(lxcBBBB)`, bypassing kernel routing entirely |
| 7.1 | Cilium eBPF program on `lxcBBBB` | Creates connection tracking entry on the receiving side |
| 7.2 | Cilium eBPF program on `lxcBBBB` | Enforces ingress network policy for pod B |
| 7.3 | Linux virtual ethernet pair | Delivers the packet into pod B's network namespace |
