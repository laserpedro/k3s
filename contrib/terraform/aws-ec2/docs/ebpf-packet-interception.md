# eBPF packet interception and kernel stack bypass

This document explains exactly where Cilium's extended Berkeley Packet Filter
programs intercept packets in the Linux kernel processing pipeline, and how the
`bpf_redirect` function bypasses the routing subsystem and netfilter entirely
for packet delivery. The full end-to-end path from the sending pod to the
receiving pod is shown across both nodes.

The example uses the following addresses throughout:

```
Server node:   10.0.1.10   (EC2 private IP)
Agent node:    10.0.1.20   (EC2 private IP)

Pod A:         10.42.0.2   (running on server node)
Pod B:         10.42.1.2   (running on agent node)
```

---

## The Linux kernel network stack as a pipeline

When a packet arrives at a network interface, the kernel processes it through a
fixed sequence of subsystems. The traffic control ingress hook is the first
software touch point after the hardware driver — nothing else has run yet when
Cilium's program executes.

```
                    PACKET ARRIVES
                    FROM NETWORK CARD
                          │
                          ▼
                ┌─────────────────────┐
                │   NIC DRIVER        │  The hardware passes raw bytes to
                │                     │  the kernel as a socket buffer
                │   (sk_buff created) │  (the kernel's internal packet
                └─────────┬───────────┘  representation)
                          │
                          ▼
╔═════════════════════════════════════════╗
║  TRAFFIC CONTROL INGRESS HOOK  (tc)    ║  ← CILIUM ATTACHES HERE
║                                         ║
║  This is the first software hook        ║
║  after the NIC driver.                  ║
║  Nothing has been evaluated yet.        ║
║  No iptables. No routing. Nothing.      ║
╚═════════════════════════════════════════╝
                          │
                          │  (only if no program redirects the packet)
                          ▼
                ┌─────────────────────┐
                │   netfilter         │
                │   PREROUTING hook   │  iptables NAT rules evaluated here
                └─────────┬───────────┘
                          │
                          ▼
                ┌─────────────────────┐
                │   ROUTING SUBSYSTEM │  Kernel consults routing table
                └─────────┬───────────┘
                          │
                          ▼
                ┌─────────────────────┐
                │   netfilter         │
                │   FORWARD hook      │  iptables FILTER rules evaluated here
                └─────────┬───────────┘
                          │
                          ▼
                ┌─────────────────────┐
                │   netfilter         │
                │   POSTROUTING hook  │  iptables masquerade rules here
                └─────────┬───────────┘
                          │
                          ▼
                    PACKET LEAVES
                    NETWORK INTERFACE
```

---

## Full end-to-end path: pod A to pod B across two nodes

```
╔══════════════════════════════════════════╗         ╔══════════════════════════════════════════╗
║  SERVER NODE  10.0.1.10                 ║         ║  AGENT NODE  10.0.1.20                  ║
║                                          ║         ║                                          ║
║  ┌────────────────────────────────────┐  ║         ║  ┌────────────────────────────────────┐  ║
║  │  POD A NETWORK NAMESPACE           │  ║         ║  │  POD B NETWORK NAMESPACE           │  ║
║  │                                    │  ║         ║  │                                    │  ║
║  │  eth0  10.42.0.2                   │  ║         ║  │  eth0  10.42.1.2                   │  ║
║  │   │                                │  ║         ║  │   ▲                                │  ║
║  │   │  pod process writes packet     │  ║         ║  │   │  pod process reads packet      │  ║
║  │   │  src 10.42.0.2                 │  ║         ║  │   │  src 10.42.0.2                 │  ║
║  │   │  dst 10.42.1.2                 │  ║         ║  │   │  dst 10.42.1.2                 │  ║
║  └───┼────────────────────────────────┘  ║         ║  └───┼────────────────────────────────┘  ║
║      │ virtual ethernet pair             ║         ║      │ virtual ethernet pair             ║
║  ────┼────── host network namespace ───  ║         ║  ────┼────── host network namespace ───  ║
║      ▼                                   ║         ║      │                                   ║
║  ╔══════════════════════════════════╗    ║         ║  ╔══════════════════════════════════╗    ║
║  ║  TC INGRESS HOOK on lxcAAAA     ║    ║         ║  ║  TC INGRESS HOOK on lxcBBBB     ║    ║
║  ║  ┌──────────────────────────┐   ║    ║         ║  ║  ┌──────────────────────────┐   ║    ║
║  ║  │ Cilium eBPF program      │   ║    ║         ║  ║  │ Cilium eBPF program      │   ║    ║
║  ║  │                          │   ║    ║         ║  ║  │                          │   ║    ║
║  ║  │ 1. connection tracking   │   ║    ║         ║  ║  │ 1. connection tracking   │   ║    ║
║  ║  │    → create new entry    │   ║    ║         ║  ║  │    → record flow         │   ║    ║
║  ║  │                          │   ║    ║         ║  ║  │                          │   ║    ║
║  ║  │ 2. policy check          │   ║    ║         ║  ║  │ 2. ingress policy check  │   ║    ║
║  ║  │    → pod A allowed?      │   ║    ║         ║  ║  │    → pod B allows src?   │   ║    ║
║  ║  │                          │   ║    ║         ║  ║  │                          │   ║    ║
║  ║  │ 3. destination type      │   ║    ║         ║  ║  │ 3. TC_ACT_OK             │   ║    ║
║  ║  │    → pod IP, no DNAT     │   ║    ║         ║  ║  │    → deliver to pod B    │   ║    ║
║  ║  │                          │   ║    ║         ║  └──────────────────────────────┘   ║    ║
║  ║  │ 4. TC_ACT_OK             │   ║    ║         ║        │                            ║    ║
║  ║  │    → pass to kernel      │   ║    ║         ║        │ virtual ethernet pair      ║    ║
║  ║  └──────────────────────────┘   ║    ║         ║        │                            ║    ║
║  ╚══════════════════════════════════╝    ║         ║  ╔═════▲════════════════════════╗    ║    ║
║      │                                   ║         ║  ║  TC INGRESS HOOK on eth0   ║    ║    ║
║      │  ✗ netfilter PREROUTING skipped   ║         ║  ║  ┌──────────────────────┐  ║    ║    ║
║      ▼                                   ║         ║  ║  │ Cilium eBPF program  │  ║    ║    ║
║  ┌──────────────────────────────────┐    ║         ║  ║  │                      │  ║    ║    ║
║  │  KERNEL ROUTING TABLE            │    ║         ║  ║  │ endpoint map lookup  │  ║    ║    ║
║  │                                  │    ║         ║  ║  │ 10.42.1.2 → lxcBBBB │  ║    ║    ║
║  │  10.42.1.0/24 via 10.0.1.20     │    ║         ║  ║  │                      │  ║    ║    ║
║  │  installed by Cilium             │    ║         ║  ║  │ bpf_redirect(lxcBBBB)│  ║    ║    ║
║  │  autoDirectNodeRoutes            │    ║         ║  ║  └──────────┬───────────┘  ║    ║    ║
║  └──────────────┬───────────────────┘    ║         ║  ╚════════════║══════════════╝    ║    ║
║                 │                         ║         ║               ║                    ║    ║
║      ✗ netfilter FORWARD skipped          ║         ║  ✗ netfilter PREROUTING  skipped   ║    ║
║      ✗ netfilter POSTROUTING skipped      ║         ║  ✗ routing table         skipped   ║    ║
║                 │                         ║         ║  ✗ netfilter FORWARD     skipped   ║    ║
║                 ▼                         ║         ║  ✗ netfilter POSTROUTING skipped   ║    ║
║  ┌──────────────────────────────────┐    ║         ║               ║                    ║    ║
║  │  eth0  10.0.1.10                 │    ║         ║               ╚══► lxcBBBB         ║    ║
║  │                                  │    ║         ║                    tc ingress hook  ║    ║
║  │  ARP: MAC of 10.0.1.20           │    ║         ║                    (above)          ║    ║
║  │  Ethernet frame:                 ├────╫─────────╫──────────────►                     ║    ║
║  │    src MAC = server MAC          │    ║   AWS   ║                                     ║    ║
║  │    dst MAC = agent  MAC          │    ║ network ║                                     ║    ║
║  │    src IP  = 10.42.0.2           │    ║ fabric  ║                                     ║    ║
║  │    dst IP  = 10.42.1.2           │    ║         ║                                     ║    ║
║  └──────────────────────────────────┘    ║         ║                                     ║    ║
╚══════════════════════════════════════════╝         ╚══════════════════════════════════════╝
```

---

## What the diagram reveals — two interception points, not one

### Interception point 1 — lxcAAAA on the sending node

The first time Cilium intercepts the packet is at the traffic control ingress
hook of `lxcAAAA`, the moment the packet crosses from pod A's network namespace
into the host network namespace. This is where all the decisions are made:

- **Connection tracking**: a new entry is created recording this flow so that
  return packets can be matched and the reverse address translation can be
  applied on the way back.
- **Policy check**: the egress network policy for pod A is evaluated. If no
  policy permits this connection, the packet is dropped here and never reaches
  the network.
- **Destination type**: the program checks whether the destination is a pod IP
  address (no translation needed) or a Service ClusterIP address (destination
  network address translation must be applied before any routing decision is
  made).

The program then returns `TC_ACT_OK`, which tells the kernel to continue
processing the packet through the normal stack. This is a deliberate choice:
because the destination pod is on a remote node, the packet must travel over the
physical interface, and the kernel routing subsystem is needed to determine which
interface to use and what the next hop address is. Cilium uses the routing table
for cross-node forwarding — it installed the route itself via
`autoDirectNodeRoutes`, and now it relies on the kernel to execute the lookup.

Netfilter is not entered. The traffic control hook runs before netfilter's
PREROUTING hook, and once the packet reaches the routing subsystem, it is
forwarded directly to the physical interface without passing through the FORWARD
or POSTROUTING hooks.

### Interception point 2 — eth0 on the receiving node

The second interception happens on the agent node at the traffic control ingress
hook of the physical `eth0` interface. When the packet arrives from the AWS
network fabric, the Cilium program on this hook runs before anything else:

- **Endpoint map lookup**: the program looks up the destination IP address
  `10.42.1.2` in a hash table that maps pod IP addresses to the interface index
  of each pod's host-side virtual ethernet interface. It finds the entry
  pointing to `lxcBBBB`.
- **bpf_redirect**: the program calls `bpf_redirect(lxcBBBB)`, which moves the
  socket buffer — the kernel's internal representation of the packet — directly
  to the receive queue of `lxcBBBB`.

At this point the packet reappears at the traffic control ingress hook of
`lxcBBBB` as if it had just arrived from a network interface. The entire
receiving node's kernel stack below the traffic control hook is skipped: the
routing table is never consulted, and netfilter's PREROUTING, FORWARD, and
POSTROUTING hooks are never entered.

### Why the routing table is used on the sending side but bypassed on the receiving side

This asymmetry is intentional. On the sending node, the packet needs to cross
to a different physical machine, which requires the kernel to build an Ethernet
frame addressed to the agent node's MAC address. The routing subsystem is the
kernel component that resolves the next hop and hands the packet to the correct
outgoing interface. Cilium lets the kernel do this work because it is the right
tool for cross-node forwarding.

On the receiving node, the destination is a local pod. The kernel routing table
on the agent node would normally route the packet to `cilium_host` — a virtual
interface Cilium manages — and from there Cilium would eventually forward it to
the pod. Using `bpf_redirect` at the first possible hook skips all of that
intermediate handling. Cilium already knows the exact destination interface from
its endpoint map, so there is no value in letting the packet descend through
routing and netfilter only to have them pass it back up to Cilium anyway.

---

## What bpf_redirect does physically

`bpf_redirect` does not copy the packet. It takes the pointer to the socket
buffer and places it into the receive queue of the destination interface. The
data itself does not move in memory — only the reference to it is transferred.
This makes the operation fast regardless of the size of the packet.

```
Socket buffer in kernel memory:
  [ Ethernet header | IP header | TCP header | payload ]
         ▲
         │ pointer held by eth0 receive queue
         │
         │  bpf_redirect(lxcBBBB) called
         │
         │ same pointer, same memory location
         ▼
         │ pointer now held by lxcBBBB receive queue
```

The subsystems that are bypassed never receive a reference to the socket buffer
at all. From their perspective, the packet does not exist.

---

## Subsystems entered and skipped on each node

```
Sending node (server):                Receiving node (agent):

ENTERED:                              ENTERED:
  tc ingress on lxcAAAA  ✓              tc ingress on eth0     ✓
  kernel routing table   ✓              tc ingress on lxcBBBB  ✓

SKIPPED:                              SKIPPED:
  netfilter PREROUTING   ✗              netfilter PREROUTING   ✗
  netfilter FORWARD      ✗              kernel routing table   ✗
  netfilter POSTROUTING  ✗              netfilter FORWARD      ✗
                                        netfilter POSTROUTING  ✗
```

On the sending node, the routing table is used because cross-node forwarding
genuinely requires it. On the receiving node, nothing below the first traffic
control hook is entered because `bpf_redirect` delivers the packet directly to
its destination before the kernel has a chance to process it further.
