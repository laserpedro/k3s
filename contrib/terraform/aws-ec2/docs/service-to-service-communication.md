# Service-to-service communication

This document explains in full detail every step a network packet takes when a
pod sends traffic to a Kubernetes Service (a ClusterIP address) that is backed
by a pod running on a different node. This is distinct from direct pod-to-pod
communication: the sender does not know the destination pod address — it only
knows the Service virtual address.

The example uses the following addresses throughout:

```
Server node:          10.0.1.10   (EC2 private IP)
Agent node:           10.0.1.20   (EC2 private IP)

Pod A (client):       10.42.0.2   running on server node
Pod B (backend):      10.42.1.2   running on agent node

Service ClusterIP:    10.43.0.50  port 80  (virtual, no real interface)
Service backing pod:  10.42.1.2   port 8080 (pod B's real address and port)
```

---

## What a Kubernetes Service is

A **Kubernetes Service** is a stable virtual IP address and port that acts as
a front-end for one or more backing pods. The ClusterIP address (`10.43.0.50`)
does not belong to any real network interface anywhere in the cluster. It is
purely an abstraction: when a packet is sent to it, something in the network
stack must rewrite the destination to the real IP address of one of the backing
pods before the packet can be delivered.

In a traditional Kubernetes cluster, **kube-proxy** is responsible for this
rewriting. It watches the Kubernetes API server for Service and Endpoints
objects and translates them into iptables rules. Every packet destined for a
ClusterIP address passes through those iptables chains, which perform the
address rewriting using netfilter.

In this cluster, kube-proxy is **disabled** (`--disable-kube-proxy` on the k3s
server, `kubeProxyReplacement = true` in the Cilium Helm chart). Cilium performs
all service load balancing entirely in extended Berkeley Packet Filter programs,
with no iptables involvement.

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
│ lxcAAAA      │    ClusterIP detected        │ lxcBBBB      │    connection tracking
└──────┬───────┘    DNAT: 10.43.0.50:80      └──────▲───────┘    policy check
       │                  → 10.42.1.2:8080           │
       │            connection tracking               │  Step 6: bpf_redirect()
       │            policy check                      │  endpoint map lookup
       │                                             │  10.42.1.2 → lxcBBBB
       │  Step 2: kernel routing table               │
       │  10.42.1.0/24 via 10.0.1.20                │
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

The key difference from direct pod-to-pod communication is **Step 1**: the
Cilium extended Berkeley Packet Filter program rewrites the destination address
from the Service ClusterIP to the real pod IP before the packet ever reaches the
kernel routing subsystem. From step 2 onward, the packet travels exactly as in
pod-to-pod communication, with a real pod address as its destination.

---

## Step 1 — Pod A sends to a Service: Cilium extended Berkeley Packet Filter program on `lxcAAAA`

### 1.1 Pod A writes a packet addressed to the ClusterIP

Pod A's process opens a connection to port 80 of the Service ClusterIP
`10.43.0.50`. The kernel in pod A's network namespace creates a socket and
writes a packet:

```
Source IP:        10.42.0.2   port 54321  (ephemeral port assigned by kernel)
Destination IP:   10.43.0.50  port 80
```

Pod A has no knowledge of pod B's address. It only knows the Service address
because it came from a Kubernetes environment variable or a DNS lookup of the
Service name (CoreDNS resolves the Service name to `10.43.0.50`).

The packet is written into pod A's `eth0` inside its network namespace, crosses
the virtual ethernet pair, and arrives at `lxcAAAA` in the host network
namespace.

### 1.2 Traffic control ingress hook — Cilium program intercepts the packet

The Cilium extended Berkeley Packet Filter program attached to the traffic
control ingress hook of `lxcAAAA` runs before the kernel routing subsystem. The
first thing the program does is inspect the destination address.

### 1.3 Service map lookup — recognising the ClusterIP

Cilium maintains a **Service map** in kernel memory (a Berkeley Packet Filter
hash table). It is populated by the Cilium operator, which watches the
Kubernetes API server for Service and Endpoints objects. When a Service is
created or its backing pods change, the operator updates this map with the new
information.

The map entry for the Service in this example looks like this:

```
Service map entry:
  Key:   10.43.0.50  port 80  protocol TCP
  Value: [10.42.1.2:8080]     ← list of backing pod endpoints
```

The program looks up the destination `10.43.0.50:80` in the Service map. It
finds a match, which means the destination is a virtual ClusterIP that must be
rewritten.

### 1.4 Backend selection — choosing a pod endpoint

The Service map value contains a list of all healthy backing pod endpoints. The
program selects one using a consistent hashing algorithm that takes the source
IP address and port into account. This ensures that all packets belonging to the
same connection always go to the same backing pod, which is necessary for
stateful protocols like TCP.

In this example there is only one backing pod (`10.42.1.2:8080`), so the
selection is deterministic.

### 1.5 Destination network address translation — rewriting the destination

The program rewrites the packet's destination address and port:

```
Before DNAT:
  Destination IP:    10.43.0.50   port 80   ← virtual ClusterIP
  Source IP:         10.42.0.2    port 54321

After DNAT:
  Destination IP:    10.42.1.2    port 8080  ← real pod B address
  Source IP:         10.42.0.2    port 54321  ← unchanged
```

This rewriting happens entirely in kernel space, inside the extended Berkeley
Packet Filter program, with no iptables rules involved. The program also updates
the TCP or UDP checksum in the packet header to reflect the changed addresses.

```
lxcAAAA — traffic control ingress hook
          │
          ▼
┌──────────────────────────────────────────────────────────────────┐
│  Cilium extended Berkeley Packet Filter program                  │
│                                                                  │
│  Destination: 10.43.0.50:80 → Service map lookup → MATCH        │
│                                                                  │
│  Backend selection: consistent hash → 10.42.1.2:8080            │
│                                                                  │
│  DNAT:  dst 10.43.0.50:80  →  10.42.1.2:8080                   │
│         checksum updated                                         │
│                                                                  │
│  Packet now carries dst = 10.42.1.2:8080                        │
└──────────────────────────────────────────────────────────────────┘
```

### 1.6 Connection tracking entry — recording the translation

The program creates a connection tracking entry that records the full
translation:

```
Connection tracking entry (server node, egress):
  Original source:       10.42.0.2   port 54321
  Original destination:  10.43.0.50  port 80     ← the ClusterIP the pod used
  Translated source:     10.42.0.2   port 54321   ← unchanged
  Translated destination:10.42.1.2   port 8080    ← the real pod address
  State:                 new
  Direction:             egress
```

This entry is critical for the **return path**. When pod B replies, its response
packet will have source `10.42.1.2:8080` and destination `10.42.0.2:54321`.
The Cilium program on the server node must recognise that this is a reply to a
translated connection and perform the **reverse translation** (source network
address translation): rewriting the source from `10.42.1.2:8080` back to
`10.43.0.50:80` before delivering the packet to pod A. Without the connection
tracking entry, the return packet would arrive at pod A with an unexpected
source address (`10.42.1.2`) that does not match the ClusterIP the pod
connected to (`10.43.0.50`), and the pod's socket would reject it.

### 1.7 Network policy enforcement

The program evaluates the egress network policy for pod A. The lookup uses the
**post-translation** destination identity (pod B's labels), not the Service's
identity. This means network policies can be written against the backing pod's
labels to control access at the pod level.

```
Source identity:      pod A labels, e.g. app=frontend
Destination identity: pod B labels, e.g. app=backend
Port and protocol:    8080 / TCP   ← post-translation port

Result: ALLOW  →  packet continues
        DROP   →  packet discarded
```

---

## Step 2 — Kernel routing table: same as pod-to-pod

After the extended Berkeley Packet Filter program has rewritten the destination
to `10.42.1.2`, the packet enters the Linux kernel routing subsystem with a real
pod IP address as its destination. The routing table lookup is identical to the
pod-to-pod case:

```
Destination        Next hop          Interface
10.42.1.0/24       10.0.1.20         eth0
```

This route was installed by Cilium's control plane via `autoDirectNodeRoutes`
when the agent node registered its pod CIDR. The kernel resolves the next hop
to `10.0.1.20`.

---

## Step 3 — Address Resolution Protocol: same as pod-to-pod

The kernel resolves the MAC address of `10.0.1.20` through the Address
Resolution Protocol and builds the Ethernet frame:

```
Ethernet header:
  Source MAC:      server eth0 MAC
  Destination MAC: agent eth0 MAC

IP header:
  Source IP:       10.42.0.2    port 54321
  Destination IP:  10.42.1.2    port 8080    ← real pod address, after DNAT
```

The ClusterIP address `10.43.0.50` is no longer visible anywhere in the packet.
The translation was completed in Step 1.

---

## Step 4 — AWS network fabric: same as pod-to-pod

The frame leaves the server node's `eth0`. The AWS network fabric delivers it
to the agent node using the destination MAC address. The `source_dest_check =
false` setting on both instances allows this delivery even though the IP
addresses in the packet are pod addresses, not the node addresses assigned to
the network interface cards.

---

## Step 5 — Packet arrives at the agent node

The agent node's network interface card receives the Ethernet frame. It contains
a packet with source `10.42.0.2:54321` and destination `10.42.1.2:8080`. There
is no longer any indication that this packet was originally addressed to a
ClusterIP. The translation was performed entirely on the server node.

---

## Step 6 — Cilium extended Berkeley Packet Filter program on agent `eth0`: endpoint redirect

The Cilium program on the agent's `eth0` traffic control ingress hook looks up
`10.42.1.2` in the endpoint map:

```
Endpoint map (agent node):
  10.42.1.2  →  lxcBBBB
```

It calls `bpf_redirect(lxcBBBB)`, injecting the packet directly into `lxcBBBB`
and bypassing the kernel routing subsystem and netfilter entirely.

---

## Step 7 — Cilium extended Berkeley Packet Filter program on `lxcBBBB`: ingress policy and delivery

The Cilium program on `lxcBBBB` runs the same steps as in the pod-to-pod case:

- Creates a connection tracking entry on the receiving side for this flow.
- Evaluates the ingress network policy for pod B.
- If the policy allows it, the packet crosses the virtual ethernet pair and
  arrives at pod B's `eth0` with destination port `8080`.

Pod B's process reads the packet from its listening socket and processes the
request.

---

## The return path — reverse address translation

When pod B sends a reply, the packet originates as:

```
Source IP:       10.42.1.2   port 8080
Destination IP:  10.42.0.2   port 54321
```

This reply travels from the agent node to the server node following the same
steps as pod-to-pod communication in the reverse direction. When it arrives at
the server node's `eth0`, the Cilium extended Berkeley Packet Filter program on
the traffic control ingress hook of the server's `eth0` intercepts it, looks it
up in the connection tracking table, finds the existing translation entry, and
performs **source network address translation**:

```
Before reverse SNAT:
  Source IP:       10.42.1.2   port 8080   ← real pod B address
  Destination IP:  10.42.0.2   port 54321

After reverse SNAT:
  Source IP:       10.43.0.50  port 80     ← restored to ClusterIP
  Destination IP:  10.42.0.2   port 54321
```

The reply is then redirected to `lxcAAAA` and delivered to pod A. Pod A's socket
sees the reply arriving from `10.43.0.50:80`, which matches the address it
connected to. The translation is completely transparent to the application.

---

## Responsibility summary

| Step | Component responsible | What it does |
|---|---|---|
| 1.1 | Pod A process + CoreDNS | Pod resolves Service name to ClusterIP; sends packet to ClusterIP |
| 1.2 | Linux traffic control on `lxcAAAA` | Provides ingress hook where Cilium program attaches |
| 1.3 | Cilium eBPF program on `lxcAAAA` | Looks up destination in Service map, finds ClusterIP match |
| 1.4 | Cilium eBPF program on `lxcAAAA` | Selects a backend pod endpoint using consistent hashing |
| 1.5 | Cilium eBPF program on `lxcAAAA` | Rewrites destination from ClusterIP to real pod address (DNAT) |
| 1.6 | Cilium eBPF program on `lxcAAAA` | Creates connection tracking entry recording the translation |
| 1.7 | Cilium eBPF program on `lxcAAAA` | Enforces egress network policy against post-translation pod identity |
| 2   | Linux kernel routing table | Resolves next hop for real pod address to `10.0.1.20` |
| 2   | Cilium control plane (`autoDirectNodeRoutes`) | Installed that route by watching Kubernetes Node objects |
| 3   | Linux Address Resolution Protocol | Resolves MAC address of `10.0.1.20` |
| 4   | AWS network fabric | Delivers Ethernet frame to agent node using destination MAC |
| 4   | `source_dest_check = false` on both EC2 instances | Allows delivery of frames carrying pod IP addresses |
| 6   | Cilium eBPF program on agent `eth0` | Endpoint map lookup; redirects packet to `lxcBBBB` |
| 7   | Cilium eBPF program on `lxcBBBB` | Connection tracking, ingress policy, delivery to pod B |
| Return | Cilium eBPF program on server `eth0` | Reverse SNAT: rewrites reply source from pod B back to ClusterIP |
