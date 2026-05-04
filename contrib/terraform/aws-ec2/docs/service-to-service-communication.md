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

---

## Why Cilium scales better than kube-proxy

### How kube-proxy works

kube-proxy is a user-space process that watches the Kubernetes API server for
Service and Endpoints objects. Each time a Service is created, updated, or
deleted, kube-proxy translates the current state of all Services and all their
backing endpoints into a set of **iptables rules** and writes them into the
Linux kernel's netfilter subsystem.

To handle destination network address translation for a Service with three
backing pods, kube-proxy generates rules roughly like the following:

```
PREROUTING chain:
  match dst=10.43.0.50:80 → jump to KUBE-SVC-XXXXX

KUBE-SVC-XXXXX chain:
  33% probability → jump to KUBE-SEP-AAA   (pod 1)
  50% probability → jump to KUBE-SEP-BBB   (pod 2, 50% of remaining 67%)
  100%            → jump to KUBE-SEP-CCC   (pod 3, all remaining)

KUBE-SEP-AAA chain:
  DNAT dst → 10.42.0.2:8080

KUBE-SEP-BBB chain:
  DNAT dst → 10.42.1.2:8080

KUBE-SEP-CCC chain:
  DNAT dst → 10.42.2.2:8080
```

For every packet destined for any Service, the kernel must walk through these
chains sequentially until it finds a matching rule.

---

### Problem 1 — rule traversal time grows linearly with cluster size

iptables rules form an ordered list. Matching a packet against a rule means
comparing fields (destination IP, port, protocol) one rule at a time, from the
top of the chain downward, until a match is found or the chain is exhausted.

With S services averaging E endpoints each, the total number of rules is
proportional to S × E. The average number of rules a packet must traverse before
finding its match is proportional to half that number:

```
Average rules traversed per packet  ≈  (S × E) / 2
```

This is an **O(S × E)** operation per packet. As the cluster grows, every single
packet pays a higher processing cost.

A concrete illustration:

```
Cluster size    Services    Endpoints    Rules generated    Avg rules per packet
────────────    ────────    ─────────    ───────────────    ────────────────────
Small              100          500           ~2 000                ~1 000
Medium           1 000        5 000          ~20 000               ~10 000
Large           10 000       50 000         ~200 000              ~100 000
```

In a large cluster, every service packet causes the CPU to evaluate one hundred
thousand comparisons. This happens in the kernel, synchronously, on the critical
path of packet delivery.

Cilium uses a **hash table** (a Berkeley Packet Filter map). The lookup for any
Service takes a fixed number of operations regardless of how many Services exist:
hash the key, index into the table, read the value. This is an **O(1)**
operation. A cluster with ten thousand Services costs exactly the same per packet
as a cluster with ten Services.

```
kube-proxy:   packet cost = O(S × E)   grows with cluster size
Cilium:       packet cost = O(1)        constant regardless of cluster size
```

---

### Problem 2 — rule updates require a full ruleset rewrite

When a pod is added to or removed from a Service (because a Deployment scales
up, a rolling update progresses, or a pod crashes), kube-proxy must update the
iptables rules. However, iptables does not support modifying individual rules in
isolation. To change anything, kube-proxy must:

1. Read the entire current ruleset out of the kernel.
2. Compute the new complete ruleset in user space.
3. Write the entire new ruleset back into the kernel atomically.

Step 3 acquires a **global iptables lock**. While this lock is held, the kernel
cannot evaluate any iptables rule for any packet anywhere on the node. All
packets that would match netfilter rules are stalled until the lock is released
and the new ruleset is installed.

The time this takes grows with the total number of rules:

```
Update cost = O(total rules in the entire ruleset)
```

In a large cluster with frequent pod churn (rolling deployments, autoscaling,
health check failures), kube-proxy may be rewriting hundreds of thousands of
rules many times per minute. Each rewrite introduces a brief period where
packets experience elevated latency or loss, and the CPU time consumed by the
rewrites competes with actual application workloads.

Cilium maintains its Service state in Berkeley Packet Filter hash maps. When a
pod is added or removed, the Cilium operator updates **only the affected map
entry**:

```
// Adding a new backend pod to a Service
bpf_map_update_elem(&service_map, &key, &new_backend, BPF_ANY);
```

This is an **O(1)** operation that does not touch any other map entry. It takes
microseconds and requires no global lock. Packets on unrelated Services are
completely unaffected.

```
kube-proxy:   update cost = O(total rules)    locks the entire node briefly
Cilium:       update cost = O(1)              atomic single-entry update, no lock
```

---

### Problem 3 — the kernel path is longer with iptables

netfilter, the kernel subsystem that evaluates iptables rules, processes packets
at a specific set of hooks in the kernel network stack. A packet travelling
through a node passes through several of these hooks, and at each one the kernel
must traverse whichever chains apply:

```
kube-proxy / iptables packet path:

  NIC receives packet
    │
    ▼
  netfilter PREROUTING hook
    → traverse NAT PREROUTING chain (DNAT here)
    │
    ▼
  kernel routing decision
    │
    ▼
  netfilter FORWARD hook
    → traverse FILTER FORWARD chain (accept/drop)
    │
    ▼
  netfilter POSTROUTING hook
    → traverse NAT POSTROUTING chain (masquerade/SNAT)
    │
    ▼
  packet leaves NIC
```

Each hook is a mandatory stop. Even if no rules match, the kernel must enter
each hook, walk the default chains, and reach the end before continuing. This
adds multiple fixed overheads to every packet, completely independent of the
rules themselves.

Cilium attaches its extended Berkeley Packet Filter program to the **traffic
control ingress hook** of the virtual ethernet interface, which runs before
netfilter. When Cilium handles a packet, it performs the entire service lookup,
destination network address translation, connection tracking, and policy
enforcement in a single pass through one program. For locally delivered packets
it uses `bpf_redirect` to inject the packet directly into the destination
interface, bypassing the routing subsystem and all netfilter hooks entirely:

```
Cilium packet path:

  NIC receives packet (or virtual ethernet pair)
    │
    ▼
  traffic control ingress hook
    → Cilium eBPF program:
        service map lookup      O(1)
        DNAT if needed          in-place rewrite
        connection tracking     BPF map update
        policy check            BPF map lookup
        bpf_redirect            inject to destination veth
    │
    ▼
  packet delivered to pod  (netfilter: skipped entirely)
```

The number of kernel subsystems the packet passes through is smaller, and the
cost of each stop does not grow with cluster size.

---

### Problem 4 — probabilistic load balancing creates uneven distribution

kube-proxy distributes traffic across backends using chained probability rules.
For three backends, the first rule fires with 33% probability, the second with
50% of the remaining 67% (which is approximately 33%), and the third catches
everything else. This works correctly in expectation but relies on randomness,
which means short-lived connections or small traffic volumes can produce
noticeably uneven distribution.

Cilium uses **Maglev consistent hashing**. For each Service, Cilium precomputes
a lookup table (of configurable size, default 65537 entries) where each backend
pod is assigned a number of slots proportional to its weight. The slot for a
given connection is determined by hashing the five-tuple (source IP, source
port, destination IP, destination port, protocol). This produces a deterministic
and highly uniform distribution:

- Two packets with the same five-tuple always go to the same backend, providing
  connection affinity without requiring stateful tracking of which backend was
  chosen.
- When a backend is added or removed, only the slots that were assigned to it
  are redistributed. Existing connections to other backends are not disrupted.

---

### Summary of scaling differences

```
Property                      kube-proxy (iptables)          Cilium (eBPF)
────────────────────────────  ─────────────────────────────  ──────────────────────────────
Per-packet service lookup     O(S × E) — linear chain walk   O(1) — hash table lookup
Rule/map update on pod change O(total rules) — full rewrite  O(1) — single map entry
Locking during update         Global iptables lock           None — atomic per-entry update
Kernel hooks traversed        PREROUTING + FORWARD +         One tc ingress hook
                              POSTROUTING (always)
Load balancing algorithm      Chained probability (uneven    Maglev consistent hashing
                              on small sample sizes)         (deterministic, uniform)
Observability                 None built in                  Hubble: per-flow metrics,
                                                             drop reasons, latency
```

At the scale of two nodes this difference is not measurable in practice. The
reason for documenting it here is that the architectural choice made at
provisioning time (disabling kube-proxy, enabling Cilium kube-proxy
replacement) is what determines whether the cluster can grow to hundreds of
nodes and tens of thousands of services without degrading per-packet latency or
spending significant CPU time on network rule management.
