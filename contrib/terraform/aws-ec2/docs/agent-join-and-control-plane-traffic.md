# Agent join and control plane traffic

This document explains in full detail every connection that exists between the
agent node and the server node once the cluster is running. It covers the
initial join sequence, the persistent watch connection the kubelet maintains to
the API server, the reverse channel the API server uses to reach the kubelet,
and the Cilium agent health probe mechanism.

The example uses the following addresses throughout:

```
Server node:   10.0.1.10   port 6443  (Kubernetes API server)
Agent node:    10.0.1.20   port 10250 (kubelet API)
               10.0.1.20   port 4240  (Cilium health endpoint)
```

---

## Overview of control plane connections

Once the cluster is running, three persistent categories of traffic flow between
the two nodes. All of them use the nodes' private IP addresses and never leave
the subnet.

```
SERVER NODE (10.0.1.10)                    AGENT NODE (10.0.1.20)
───────────────────────                    ──────────────────────

k3s API server                             kubelet
  :6443          ◄── HTTPS (persistent) ───  watches assigned pods
                                             Cilium agent watches
                                             nodes and endpoints

k3s API server                             kubelet API
  :6443          ─── HTTPS (on demand) ───►  :10250
                     exec / logs /           streams output
                     port-forward            back to caller

Cilium agent                               Cilium agent
  :4240          ◄── TCP (periodic)  ────►  :4240
                     health probes           health probes
                     both directions
```

None of this traffic passes through the Cilium pod networking overlay. These
are node-to-node connections using the instance private IP addresses, routed
directly by the Linux kernel's host routing table through the AWS network
fabric.

---

## Phase 1 — Agent bootstrap and join sequence

### 1.1 The agent contacts the server bootstrap endpoint

When the k3s agent process starts on the agent node, it reads two pieces of
configuration from its environment:

- `K3S_URL`: the address of the API server — in this setup `https://10.0.1.10:6443`
- `K3S_TOKEN`: the shared cluster token written to the server during installation

The agent opens an HTTPS connection to `https://10.0.1.10:6443` and contacts a
k3s-specific bootstrap endpoint. At this point the agent does not yet have a
trusted certificate for the server, so it makes an initial unauthenticated
request to retrieve the server's certificate authority bundle.

### 1.2 Token-based authentication and certificate authority trust

The server uses the shared token as a **bootstrap credential**. The agent sends
the token in the request, and the server verifies it by comparing it to the hash
stored at cluster initialisation time. This proves the agent is authorised to
join the cluster without requiring a pre-issued client certificate.

Once the server accepts the token, it returns its certificate authority
certificate. The agent stores this locally and uses it to validate the server's
identity for all future connections. From this point on, every connection the
agent makes to `10.0.1.10:6443` is verified against this certificate authority.
A man-in-the-middle attack is not possible because any certificate not signed by
this authority will be rejected.

The server's TLS certificate includes both the private IP address
(`10.0.1.10`) and the public IP address in its Subject Alternative Names, which
is what `--tls-san` in the k3s server flags achieves. This means the agent
connecting over the private IP sees a valid certificate, and an operator
connecting kubectl from the internet over the public IP also sees a valid
certificate.

### 1.3 The agent receives its own client certificate

After trust is established, the server issues a **client certificate** to the
agent. This certificate identifies the kubelet running on the agent node and is
signed by the cluster's certificate authority. The agent stores this certificate
on disk and uses it for mutual TLS authentication on all subsequent connections
to the API server. Both sides now authenticate each other cryptographically on
every connection.

### 1.4 The agent registers itself as a Kubernetes Node object

With authentication established, the kubelet (which k3s embeds in the agent
process) creates a **Node** object in the Kubernetes API server. This object
describes the agent node's properties:

```yaml
apiVersion: v1
kind: Node
metadata:
  name: k3s-agent
spec:
  podCIDR: ""           # not yet assigned
status:
  addresses:
    - type: InternalIP
      address: 10.0.1.20
  capacity:
    cpu: "2"
    memory: 4Gi
    pods: "110"
  conditions:
    - type: Ready
      status: "False"   # not ready until CNI provides networking
```

### 1.5 Pod CIDR assignment by the node controller

The k3s server runs a **node controller** (part of the controller-manager
component) that watches for new Node objects. When it sees the agent's Node
object with an empty `spec.podCIDR`, it selects the next available block from
the cluster CIDR (`10.42.0.0/16`) and writes it into the Node object:

```yaml
spec:
  podCIDR: 10.42.1.0/24
```

The size of this block is determined by the node CIDR mask size, which defaults
to `/24` when the cluster CIDR is a `/16`.

### 1.6 Cilium reads the pod CIDR and installs kernel routes

The Cilium agent running on the **server node** is watching Node objects through
its own persistent connection to the API server. When it sees the agent Node
object updated with `spec.podCIDR = 10.42.1.0/24`, it immediately installs a
kernel route on the server node:

```
10.42.1.0/24 via 10.0.1.20 dev eth0
```

Simultaneously, the Cilium agent on the **agent node** reads its own Node
object's pod CIDR and configures the local pod network, making the node ready
to receive pods.

### 1.7 Node transitions to Ready

Once Cilium on the agent node has configured its pod networking (virtual
ethernet pairs for existing system pods, eBPF programs attached, routes
installed), it reports the node as healthy. The kubelet then updates the Node
object's status condition to `Ready: True`. The scheduler can now assign pods
to this node.

```
Join sequence timeline:

t=0s    Agent starts, reads K3S_URL and K3S_TOKEN
t=1s    Agent contacts server :6443, sends token, receives CA certificate
t=2s    Server issues client certificate to agent
t=3s    Agent creates Node object via API server
t=4s    Node controller assigns podCIDR 10.42.1.0/24 to Node object
t=5s    Cilium on server node installs route 10.42.1.0/24 via 10.0.1.20
t=5s    Cilium on agent node configures local pod network
t=10s   Node status transitions to Ready: True
```

---

## Phase 2 — Ongoing kubelet-to-API-server watch traffic (HTTPS port 6443)

### 2.1 What a Kubernetes watch connection is

After joining, the kubelet maintains a **persistent HTTPS connection** to the
API server on port 6443. This connection uses the HTTP/2 protocol, which
multiplexes multiple logical streams over a single TCP connection. One of these
streams is used for watching Kubernetes objects.

A watch is a long-lived HTTP GET request with the query parameter `watch=true`.
Rather than returning a fixed response body, the API server keeps the connection
open and sends newline-delimited JSON events over it as objects change:

```
GET /api/v1/pods?fieldSelector=spec.nodeName=k3s-agent&watch=true

← {"type":"ADDED",   "object": {"metadata": {"name": "nginx-abc"}}}
← {"type":"MODIFIED","object": {"metadata": {"name": "nginx-abc"}, ...}}
← {"type":"DELETED", "object": {"metadata": {"name": "nginx-abc"}}}
```

The kubelet receives these events immediately when the API server processes a
change, rather than discovering them on the next polling cycle. This means a pod
scheduled to the agent node begins starting within milliseconds of the scheduler
writing the pod assignment, not after a polling interval.

### 2.2 What the kubelet watches

The kubelet maintains watch connections for the following resources, filtered to
only the objects relevant to its own node:

- **Pods** where `spec.nodeName = k3s-agent` — the kubelet receives an ADDED
  event when a pod is scheduled here, starts the containers, and reports status
  back to the API server. It receives a DELETED event when a pod is evicted and
  stops the containers.
- **Secrets and ConfigMaps** referenced by pods running on this node — the
  kubelet monitors these for changes so that updated configuration or
  credentials are reflected in running containers.
- **Node** object for its own node — the kubelet watches for changes to its
  own Node object, for example when the scheduler adds a taint or an operator
  patches a label.

### 2.3 What the Cilium agent watches

The Cilium agent running on the agent node also maintains its own persistent
watch connection to the API server on port 6443. This is separate from the
kubelet's connection and watches different resources:

- **Node** objects for all nodes — Cilium watches for changes to pod CIDRs so
  it can add or remove kernel routes for cross-node pod traffic.
- **Endpoints** objects — Cilium watches which pods are backing each Service so
  it can keep its Service map (Berkeley Packet Filter map) up to date. When a
  pod becomes healthy or unhealthy, the Endpoints object is updated and Cilium
  immediately reflects this in the map used for load balancing.
- **NetworkPolicy** and **CiliumNetworkPolicy** objects — Cilium watches for
  policy changes so it can update the Berkeley Packet Filter maps used for
  policy enforcement.
- **CiliumEndpoint** objects — Cilium-specific resources that record the
  security identity and state of each pod endpoint across the cluster.

### 2.4 How the connection stays alive

An HTTP/2 connection over a long-lived TCP session would be silently dropped by
idle connection timeouts in intermediate infrastructure (firewalls, NAT devices,
the AWS network fabric) if no traffic flowed for an extended period. HTTP/2
addresses this with **PING frames** — small keep-alive messages sent
periodically by both sides to prove the connection is still live. The kubelet
and the API server both send these frames, and the absence of a reply within a
timeout triggers reconnection.

---

## Phase 3 — API-server-to-kubelet connections (HTTPS port 10250)

### 3.1 The reverse channel

All connections described so far were initiated by the agent toward the server.
There is also a reverse channel: the API server initiates connections **to** the
kubelet API on port 10250 of the agent node. This is used for operations that
require the API server to stream data from a running container.

The kubelet on the agent node exposes an HTTPS server on port 10250. It
authenticates incoming connections using the cluster's certificate authority, so
only the API server (which holds a certificate signed by the same authority) can
connect to it.

### 3.2 kubectl logs

When an operator runs `kubectl logs`, the request travels:

```
operator
  │  HTTPS
  ▼
API server (10.0.1.10:6443)
  │  HTTPS
  ▼
kubelet API (10.0.1.20:10250)
  │  reads from container runtime (containerd)
  ▼
log stream returned to operator
```

The API server opens a connection to `10.0.1.20:10250`, requests the log stream
for the specified container, and proxies the bytes back to the operator's
kubectl client. The connection to the kubelet remains open for as long as the
log stream is active (`kubectl logs -f`).

### 3.3 kubectl exec and kubectl attach

When an operator runs `kubectl exec`, the API server opens a streaming
connection to the kubelet API. The kubelet instructs the container runtime
(containerd) to create an execution session inside the running container. Input
from the operator's terminal is forwarded through:

```
operator terminal
  │  WebSocket / SPDY over HTTPS
  ▼
API server :6443
  │  HTTPS streaming
  ▼
kubelet API :10250
  │  container runtime interface
  ▼
process running inside container
```

The kubelet API keeps this connection open for the duration of the interactive
session. When the process exits, the connection is closed.

### 3.4 kubectl port-forward

When an operator runs `kubectl port-forward`, the API server opens a streaming
connection to the kubelet which creates a tunnel directly into the pod's network
namespace and forwards TCP traffic between the operator's local port and the
specified pod port.

### 3.5 Why the security group rule for port 10250 is necessary

The security group rules in this Terraform configuration include an ingress rule
on the agent's security group allowing TCP port 10250 from the server security
group. Without this rule, the AWS network fabric would drop every connection
attempt from the API server to the kubelet, making all streaming operations
(logs, exec, port-forward) fail even though the cluster itself would appear
healthy.

---

## Phase 4 — Cilium agent health probes (TCP port 4240)

### 4.1 What the Cilium health check system does

Every Cilium agent exposes an HTTP endpoint on port 4240. Every other Cilium
agent in the cluster periodically sends a probe to this endpoint to verify that
the network path between the two nodes is functioning. In a two-node cluster,
the server's Cilium agent probes the agent node's port 4240, and the agent
node's Cilium agent probes the server node's port 4240.

The probe is a plain HTTP GET request:

```
GET http://10.0.1.20:4240/hello
```

A successful response confirms that:

1. The probing node's outgoing network path to the destination node is working.
2. The destination node's Cilium agent process is running and responsive.
3. The return path from the destination back to the probing node is working
   (since the HTTP response must travel back).

### 4.2 What happens when a probe fails

If the HTTP probe to port 4240 fails (connection refused, timeout, or an
unexpected response), the Cilium agent marks the remote node's connectivity
status as degraded. This is surfaced in the output of:

```
cilium-dbg status --verbose
```

Under the connectivity section, each node's reachability is reported. A failure
here is an early warning that the routing configuration or the AWS network path
between nodes may have a problem, independent of whether Kubernetes itself has
detected a node failure.

### 4.3 Probe frequency and the two-node case

The default probe interval is 60 seconds. In a large cluster, this means the
health check system creates a mesh of probe connections — every node probes
every other node. With N nodes, there are N × (N − 1) probe paths. In a
two-node cluster there are only two probe paths (server to agent and agent to
server), so the overhead is negligible.

### 4.4 Why the security group rule is bidirectional

The security group configuration in this Terraform module includes:

- A rule on the server security group allowing TCP 4240 **inbound** from the
  agent security group — so the agent can probe the server.
- A rule on the agent security group allowing TCP 4240 **inbound** from the
  server security group — so the server can probe the agent.

Both rules are necessary because the probe runs in both directions independently.

---

## How control plane traffic is routed

All of the traffic described in this document — port 6443, port 10250, port
4240 — uses the node private IP addresses (`10.0.1.10` and `10.0.1.20`). It
does not pass through the Cilium pod network overlay.

When the kubelet on the agent node opens a TCP connection to `10.0.1.10:6443`,
the packet's path is:

```
kubelet process (agent node, user space)
  │  writes to socket
  ▼
Linux kernel TCP stack (agent node host network namespace)
  │  source: 10.0.1.20   destination: 10.0.1.10:6443
  ▼
host routing table
  │  10.0.1.0/24 dev eth0   ← both nodes are in the same subnet
  ▼
eth0 (10.0.1.20)
  │  Ethernet frame: dst MAC = server eth0 MAC
  ▼
AWS network fabric (Layer 2 within subnet)
  │
  ▼
eth0 (10.0.1.10)
  │
  ▼
Linux kernel TCP stack (server node host network namespace)
  │
  ▼
k3s API server process (server node, user space, port 6443)
```

This is entirely different from pod-to-pod traffic in two ways:

1. **The source and destination addresses are node IP addresses**, which are
   assigned to the actual network interface cards. The `source_dest_check =
   false` setting is not needed for this traffic — AWS would accept it even with
   the check enabled.
2. **There is no Cilium eBPF program on this path**. The packets enter and leave
   through the host network namespace's `eth0` directly, bypassing the virtual
   ethernet interfaces and traffic control hooks that Cilium uses for pod traffic.
   Cilium is not involved in forwarding this traffic at all.

---

## Summary

```
Connection             Direction              Port    Protocol    Purpose
─────────────────────  ─────────────────────  ──────  ──────────  ─────────────────────────────
Bootstrap              agent → server         6443    HTTPS       Token auth, CA trust, client cert
Node registration      agent → server         6443    HTTPS       Create Node object via API
Pod CIDR watch         agent → server         6443    HTTPS       kubelet watches assigned pods
Object watch (Cilium)  agent → server         6443    HTTPS       Cilium watches nodes, endpoints,
                                                                  policies
kubectl logs           server → agent         10250   HTTPS       API server streams container logs
kubectl exec           server → agent         10250   HTTPS       API server proxies shell sessions
kubectl port-forward   server → agent         10250   HTTPS       API server tunnels TCP into pod
Health probe           server → agent         4240    HTTP        Cilium verifies agent reachable
Health probe           agent → server         4240    HTTP        Cilium verifies server reachable
```

All connections remain within the private subnet (`10.0.1.0/24`) and are
protected by mutual TLS (port 6443 and 10250) or are secured by the network
perimeter (port 4240 is restricted to the peer security group by the security
group rules and is not exposed to the internet).
