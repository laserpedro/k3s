# How the Cilium DaemonSet installs kernel-level components

A Kubernetes pod is normally an isolated, unprivileged process. Yet the Cilium
DaemonSet — which runs as a pod — manages to load eBPF programs into the Linux
kernel, create virtual ethernet pairs, attach traffic control hooks to physical
network interfaces, and write binaries onto the host filesystem. This document
explains the four mechanisms that make this possible and traces the exact
sequence of operations that occur when the DaemonSet pod starts on a node.

---

## Background — what needs to be installed and where

Before explaining how installation works, it is useful to list what Cilium
needs to put in place on each node:

```
Location                  What is installed                   Who uses it
────────────────────────  ──────────────────────────────────  ────────────────────
Linux kernel memory        eBPF programs                       kernel, on every packet
Linux kernel memory        BPF maps (hash tables)              eBPF programs
/sys/fs/bpf/              Pinned BPF map file descriptors     Cilium agent on restart
Network interface tc hook  eBPF program attachments            kernel, on every packet
Kernel routing table       Cross-node pod CIDR routes          kernel, on every packet
/opt/cni/bin/             cilium-cni binary                   kubelet, on pod creation
/etc/cni/net.d/           CNI configuration file              kubelet, on pod creation
```

The items in the first five rows live inside the kernel or are attached to
kernel data structures. The items in the last two rows are files on the host
filesystem. Different mechanisms are used to install each category.

---

## Mechanism 1 — The privileged security context

The Cilium DaemonSet pod runs with an elevated Linux security context. Rather
than running with the default restricted capability set that Kubernetes assigns
to ordinary pods, it is granted specific Linux capabilities:

```yaml
securityContext:
  privileged: true
  capabilities:
    add:
      - NET_ADMIN
      - SYS_ADMIN
      - BPF
```

Each capability unlocks a specific category of kernel operations:

**NET_ADMIN** grants permission to:
- Create and destroy network interfaces (virtual ethernet pairs, tunnel
  interfaces, the `cilium_host` virtual interface)
- Modify the kernel routing table (installing cross-node pod CIDR routes)
- Configure traffic control queuing disciplines and filters (attaching eBPF
  programs to tc ingress and egress hooks on network interfaces)
- Change interface properties such as maximum transmission unit size

**BPF** (available since Linux kernel 5.8) grants permission to:
- Call the `bpf()` system call to load eBPF programs into the kernel
- Create BPF maps in kernel memory
- Pin BPF objects to the BPF filesystem

**SYS_ADMIN** grants permission to:
- Mount filesystems (needed to mount the BPF filesystem at `/sys/fs/bpf`)
- Access process information in `/proc` on the host
- Perform other privileged kernel operations not covered by the more specific
  capabilities above

A privileged container is not isolated from the host kernel in these respects.
The namespace isolation that normally prevents a pod from touching the host
network stack or calling privileged system calls is explicitly lifted for the
Cilium pod. When the Cilium agent inside the container calls `bpf()`, the kernel
receives and executes that system call exactly as it would from a root process
running directly on the host.

---

## Mechanism 2 — `hostNetwork: true` grants direct access to the host network namespace

The Cilium DaemonSet pod is configured with `hostNetwork: true`:

```yaml
spec:
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet
```

Normally a pod runs inside its own network namespace — an isolated copy of the
Linux network stack that contains only the pod's virtual ethernet interface and
its own routing table. Processes inside the pod cannot see or modify the host's
network interfaces, routing table, or traffic control configuration.

With `hostNetwork: true`, the pod shares the host machine's network namespace
directly. There is no copy — the Cilium agent running inside the container sees
the same network interfaces, the same routing table, and the same traffic
control state as a process running natively on the host.

This is why Cilium can attach its eBPF program to the physical `eth0` interface
of the EC2 instance. The `eth0` visible inside the Cilium container is not a
virtual copy — it is the actual physical interface. When the Cilium agent
creates a virtual ethernet pair for a pod or installs a route for a remote
node's pod CIDR, those changes are made directly in the host network namespace
and are immediately visible to every other process on the node.

---

## Mechanism 3 — Host filesystem volume mounts for CNI binary installation

eBPF programs are loaded dynamically at runtime by the Cilium agent process.
However, the CNI (Container Network Interface) binary and configuration file
must be present on the host filesystem before kubelet will call Cilium to set
up networking for new pods. Cilium places these files using an **init
container** that runs to completion before the main agent container starts.

The Helm chart configures the DaemonSet with the following structure:

```yaml
initContainers:
  - name: install-cni-binaries
    image: cilium/cilium
    command: ["/install-plugin.sh"]
    volumeMounts:
      - name: cni-path
        mountPath: /host/opt/cni/bin

  - name: mount-bpf-fs
    image: cilium/cilium
    command: ["mount", "--make-shared", "/sys/fs/bpf"]
    securityContext:
      privileged: true
    volumeMounts:
      - name: bpf-maps
        mountPath: /sys/fs/bpf

containers:
  - name: cilium-agent
    volumeMounts:
      - name: cni-path
        mountPath: /host/opt/cni/bin
      - name: etc-cni-netd
        mountPath: /host/etc/cni/net.d
      - name: bpf-maps
        mountPath: /sys/fs/bpf
      - name: host-proc
        mountPath: /host/proc
        readOnly: true

volumes:
  - name: cni-path
    hostPath:
      path: /opt/cni/bin        # real directory on the host filesystem
  - name: etc-cni-netd
    hostPath:
      path: /etc/cni/net.d      # real directory on the host filesystem
  - name: bpf-maps
    hostPath:
      path: /sys/fs/bpf         # BPF filesystem on the host
  - name: host-proc
    hostPath:
      path: /proc               # host process information
```

A `hostPath` volume mount makes a directory from the host filesystem appear at
a path inside the container. When the init container writes a file to
`/host/opt/cni/bin/cilium-cni`, that file is physically written to
`/opt/cni/bin/cilium-cni` on the EC2 instance's root filesystem. The container
filesystem and the host filesystem are separate — but the `hostPath` volume
creates a window through which the container can read and write host files.

After the init containers complete, the host filesystem contains:

```
/opt/cni/bin/cilium-cni       ← CNI plugin binary, placed by init container
/etc/cni/net.d/05-cilium.conf ← CNI configuration, placed by Cilium agent
/sys/fs/bpf/                  ← BPF filesystem, mounted by init container
```

From this point on, whenever kubelet needs to set up networking for a new pod,
it reads `/etc/cni/net.d/` to find the active CNI plugin, then executes
`/opt/cni/bin/cilium-cni`. That binary runs as a host process — not inside any
container — and contacts the Cilium agent via a Unix socket to request that a
virtual ethernet pair and eBPF programs be configured for the new pod.

---

## Mechanism 4 — The `bpf()` system call loads programs into the kernel

eBPF programs are not kernel modules. They do not require rebooting the node or
modifying any kernel file. They are loaded through a standard Linux system call
named `bpf()`, available to any process that holds the `CAP_BPF` capability.

The Cilium agent calls this system call to perform three categories of
operation:

### 4.1 Loading eBPF programs

```
bpf(BPF_PROG_LOAD, {
    prog_type = BPF_PROG_TYPE_SCHED_CLS,   ← traffic control classifier type
    insns     = <compiled eBPF bytecode>,
    license   = "GPL",
})
→ returns a file descriptor referencing the loaded program
```

The kernel receives the compiled eBPF bytecode, runs it through a verifier that
proves it cannot crash the kernel or loop infinitely, compiles it to native
machine code for the CPU architecture, and stores it in kernel memory. The file
descriptor returned is a reference to this in-kernel program object.

The verifier is the security boundary. It inspects every possible execution path
through the program and rejects it if any path could access memory out of
bounds, call a disallowed kernel function, or fail to terminate. A program that
passes the verifier is guaranteed to be safe to run on every packet.

### 4.2 Creating BPF maps

```
bpf(BPF_MAP_CREATE, {
    map_type    = BPF_MAP_TYPE_HASH,
    key_size    = sizeof(struct endpoint_key),     ← pod IP address
    value_size  = sizeof(struct endpoint_info),    ← interface index
    max_entries = 65535,
})
→ returns a file descriptor referencing the map
```

BPF maps are key-value data structures that live in kernel memory and can be
read and written by both eBPF programs (during packet processing) and user-space
processes (the Cilium agent, when updating service backends or endpoint
information). The map file descriptor returned by `BPF_MAP_CREATE` is how the
Cilium agent updates map entries from user space:

```
bpf(BPF_MAP_UPDATE_ELEM, {
    map_fd = <map file descriptor>,
    key    = &pod_ip_address,
    value  = &interface_index,
    flags  = BPF_ANY,
})
```

This is how the endpoint map is kept current. When a new pod is scheduled, the
Cilium agent inserts its IP address and the index of its host-side virtual
ethernet interface into the map. The next packet arriving at the physical
`eth0` for that pod IP will find the entry immediately.

### 4.3 Pinning maps to the BPF filesystem

```
bpf(BPF_OBJ_PIN, {
    pathname = "/sys/fs/bpf/cilium/map/cilium_lxc",
    bpf_fd   = <map file descriptor>,
})
```

Pinning writes a reference to a BPF map or program into the BPF filesystem. The
BPF filesystem is a special kernel filesystem (similar to `procfs` or `sysfs`)
that holds references to BPF objects. A pinned map persists in kernel memory as
long as the pin file exists, even if the process that created the map exits. When
the Cilium agent restarts — for example during a DaemonSet update — it reopens
the pinned maps from `/sys/fs/bpf/` and continues operating with the same
connection tracking state, endpoint map, and service map that existed before
the restart. No connections are dropped during a Cilium agent upgrade.

---

## Attaching eBPF programs to network interfaces

Loading a program into the kernel produces a file descriptor, but the program
is not yet running. It must be attached to a network interface's traffic control
hook. Cilium does this through **netlink**, the standard Linux socket interface
for kernel network configuration. The sequence for attaching to `eth0` is:

```
Step 1: create a clsact queuing discipline on eth0
        (clsact is the traffic control qdisc type that supports tc hooks)

  netlink message: RTM_NEWQDISC
    interface: eth0
    qdisc:     clsact

Step 2: attach the eBPF program as a tc ingress filter

  netlink message: RTM_NEWTFILTER
    interface:   eth0
    direction:   ingress
    priority:    1
    protocol:    all
    type:        bpf
    program_fd:  <file descriptor from BPF_PROG_LOAD>
    direct_action: true   ← program return value controls packet fate
```

After step 2, the kernel calls the eBPF program on every packet that arrives at
`eth0` before any other processing. The `direct_action` flag means the program's
return value directly determines what happens to the packet — `TC_ACT_OK` passes
it to the next subsystem, `TC_ACT_REDIRECT` sends it to another interface via
`bpf_redirect`, and `TC_ACT_SHOT` drops it.

Crucially, **this attachment survives the exit of the Cilium agent process**. An
eBPF program attached to a network interface is owned by the kernel, not by the
process that loaded it. If the Cilium agent pod is restarted during a DaemonSet
rolling update, the existing eBPF programs continue running on every packet
throughout the restart. Packet forwarding is not interrupted.

---

## What happens when a new pod is scheduled to the node

Once the DaemonSet is running and the CNI binary is installed, the sequence
for setting up networking for each new pod is as follows:

```
kubelet receives a pod assignment from the API server
          │
          ▼
kubelet instructs containerd to create the pod sandbox
          │
          ▼
containerd creates a new Linux network namespace for the pod
          │
          ▼
containerd executes /opt/cni/bin/cilium-cni on the host
(this binary was placed there by the init container)
          │
          ▼
cilium-cni contacts the Cilium agent via Unix socket
/var/run/cilium/cilium.sock
          │
          ▼
Cilium agent receives the request, then via netlink:

  1. Creates a virtual ethernet pair:
       lxcAAAA in the host network namespace
       eth0    in the pod network namespace

  2. Assigns the pod's IP address to the pod-side interface
       (IP taken from the node's pod CIDR assigned by the node controller)

  3. Attaches eBPF programs to lxcAAAA:
       tc ingress hook: connection tracking, policy, DNAT
       tc egress hook:  connection tracking, policy

  4. Inserts an entry into the endpoint map:
       pod IP address → interface index of lxcAAAA

  5. Installs a local kernel route:
       pod IP address → lxcAAAA (for packets from the host to the pod)
          │
          ▼
cilium-cni returns the assigned IP address to containerd
          │
          ▼
containerd starts the containers inside the pod namespace
Pod is ready to send and receive traffic
```

---

## Full startup sequence on a new node

```
DaemonSet pod scheduled to the node
          │
          ▼
┌─────────────────────────────────────────────────────────────────┐
│  Init container 1: mount-bpf-fs                                 │
│                                                                  │
│  Mounts the BPF filesystem at /sys/fs/bpf if not already mounted│
│  Makes the mount shared so child namespaces can see it          │
└────────────────────────────────┬────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────┐
│  Init container 2: install-cni-binaries                         │
│                                                                  │
│  Copies cilium-cni binary → /opt/cni/bin/     (hostPath volume) │
│  (kubelet will call this binary for every new pod on this node) │
└────────────────────────────────┬────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────┐
│  Main container: cilium-agent                                    │
│  (hostNetwork: true — shares host network namespace)            │
│  (CAP_NET_ADMIN, CAP_BPF, CAP_SYS_ADMIN)                       │
│                                                                  │
│  On first start:                                                 │
│    bpf() BPF_PROG_LOAD    → load all eBPF programs into kernel  │
│    bpf() BPF_MAP_CREATE   → create service, endpoint, CT maps   │
│    bpf() BPF_OBJ_PIN      → pin maps to /sys/fs/bpf/            │
│    netlink RTM_NEWQDISC   → create clsact qdisc on eth0         │
│    netlink RTM_NEWTFILTER → attach ingress eBPF program to eth0 │
│    netlink RTM_NEWROUTE   → install cross-node pod CIDR routes   │
│    write /etc/cni/net.d/  → write CNI configuration file        │
│                                                                  │
│  On restart (agent upgrade):                                     │
│    bpf() BPF_OBJ_GET      → reopen pinned maps from /sys/fs/bpf │
│                             (connection tracking state preserved)│
│    tc programs already attached → packet forwarding uninterrupted│
│                                                                  │
│  Ongoing:                                                        │
│    Watch API server → update BPF maps as pods/services change   │
└─────────────────────────────────────────────────────────────────┘
```

---

## Summary — why this does not require kernel modules

A common misconception is that software operating at the kernel network level
must be a kernel module — compiled code that is dynamically linked into the
running kernel. Cilium requires no kernel module. Every kernel-level component
it installs goes through standard, stable Linux interfaces:

```
Component                  Kernel interface used
─────────────────────────  ──────────────────────────────────────────
eBPF program loading       bpf() system call with BPF_PROG_LOAD
BPF map creation           bpf() system call with BPF_MAP_CREATE
tc hook attachment         netlink socket, RTM_NEWTFILTER message
Virtual ethernet creation  netlink socket, RTM_NEWLINK message
Route installation         netlink socket, RTM_NEWROUTE message
CNI binary placement       hostPath volume mount, file copy
BPF map persistence        bpf() system call with BPF_OBJ_PIN
                           on the BPF filesystem (/sys/fs/bpf)
```

The kernel verifier enforces safety: no eBPF program that could crash the
kernel or loop forever will pass verification. The capability system enforces
authorisation: no process without `CAP_BPF` and `CAP_NET_ADMIN` can load
programs or attach hooks. The DaemonSet holds these capabilities explicitly
because the Helm chart requests them, and the cluster administrator approved the
Helm install.
