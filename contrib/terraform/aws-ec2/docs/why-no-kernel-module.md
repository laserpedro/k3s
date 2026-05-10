# Why Cilium requires no kernel module

A common assumption about software that operates at the kernel network level is
that it must be a kernel module — compiled code that is dynamically linked into
the running kernel, requiring a reboot or a privileged `insmod` operation to
install. Cilium requires none of this. Every kernel-level component it installs
goes through three standard Linux interfaces that have been part of the kernel
for years and are available to any sufficiently privileged process.

This document explains those three interfaces, the safety guarantees each one
provides, and how the Linux capability system controls who is allowed to use
them.

---

## The three standard Linux interfaces Cilium uses

### 1. The `bpf()` system call — loading programs into the kernel

The `bpf()` system call allows a user-space process to submit a program written
in eBPF bytecode to the kernel. Before the program is accepted, the kernel runs
it through a component called the **verifier**.

The verifier performs a complete static analysis of the program. It traces every
possible execution path and checks that:

- No path accesses memory outside the bounds of the packet or the BPF maps the
  program is allowed to use.
- No path calls a kernel function that is not on the allowed list for the
  program type.
- Every path terminates — the program cannot loop forever.
- All helper function arguments are of the correct type and within valid ranges.

If any path fails any check, the entire program is rejected and the `bpf()` call
returns an error. A program that passes the verifier is mathematically proven to
be safe before it ever runs on a single packet. The kernel can then compile the
verified bytecode to native machine code for the CPU architecture and store it
in kernel memory.

This is fundamentally different from a kernel module, which the kernel accepts
and executes with no safety analysis whatsoever. A buggy kernel module can
corrupt kernel memory and crash the machine. A buggy eBPF program that would do
the same thing cannot pass the verifier and is never executed.

```
User space (Cilium agent)          Kernel
──────────────────────────         ────────────────────────────────────────
bpf(BPF_PROG_LOAD, bytecode)  →   Verifier checks all execution paths
                                     ↓ reject if any path is unsafe
                                   JIT compiler: bytecode → machine code
                                   Program stored in kernel memory
                               ←   File descriptor returned to caller
```

The same system call is used to create BPF maps — hash tables stored in kernel
memory that eBPF programs and the Cilium agent read and write to exchange
information such as the endpoint map, the service map, and the connection
tracking table.

### 2. Netlink sockets — configuring the kernel network subsystem

Netlink is a standard Linux socket interface designed for communication between
user-space processes and the kernel's network subsystem. It is the same
interface used by the `ip`, `tc`, and `iproute2` tools that network
administrators use every day.

Cilium uses netlink to perform four categories of network configuration:

```
Operation                        Netlink message type
───────────────────────────────  ─────────────────────────────────
Create virtual ethernet pair     RTM_NEWLINK
Attach eBPF program to tc hook   RTM_NEWQDISC + RTM_NEWTFILTER
Install cross-node pod routes    RTM_NEWROUTE
Remove stale routes on teardown  RTM_DELROUTE
```

There is nothing exotic about these operations. The `ip link add veth ...` and
`tc filter add ... bpf ...` commands that a network engineer might type at a
shell prompt translate directly into these same netlink messages. Cilium sends
them programmatically from the agent process.

One important property of tc hook attachments made through netlink is that they
**persist after the process that created them exits**. The eBPF program is
attached to the kernel's representation of the network interface, not to the
Cilium agent process. If the Cilium agent pod is restarted during a DaemonSet
rolling update, the programs continue running on every packet throughout the
restart. Packet forwarding is not interrupted.

### 3. Host path volume mounts — placing files on the host filesystem

The CNI binary (`cilium-cni`) and the CNI configuration file must exist on the
host filesystem so that kubelet can find and execute them when creating new pods.
The Cilium DaemonSet places these files using a `hostPath` volume mount — a
Kubernetes mechanism that makes a directory from the host's real filesystem
appear at a path inside the container.

```
Inside init container        Host filesystem
─────────────────────────    ───────────────────────────────────
/host/opt/cni/bin/     ←→    /opt/cni/bin/         (hostPath)
/host/etc/cni/net.d/   ←→    /etc/cni/net.d/       (hostPath)
/sys/fs/bpf/           ←→    /sys/fs/bpf/          (hostPath)
```

When the init container copies the `cilium-cni` binary to
`/host/opt/cni/bin/cilium-cni`, that file physically appears at
`/opt/cni/bin/cilium-cni` on the EC2 instance. From that point on, kubelet
executes this binary as a host process every time it creates a new pod on the
node. The binary is not running inside any container — it runs directly on the
host and communicates with the Cilium agent over a Unix socket.

The BPF filesystem mounted at `/sys/fs/bpf/` serves a different purpose: it
gives BPF maps a persistent identity on disk. When the Cilium agent pins a map
to `/sys/fs/bpf/cilium/map/cilium_lxc`, that map stays in kernel memory as long
as the pin file exists, even if the agent process that created it exits. On
restart, the agent reopens the pinned map and continues using the same
connection tracking state, endpoint map, and service map — no existing
connections are dropped during an agent upgrade.

---

## The capability system — controlling who can use these interfaces

The three interfaces above are not open to every process on the system. The
Linux capability system gates access to each one:

```
Capability      What it permits
──────────────  ──────────────────────────────────────────────────────────
CAP_BPF         Call bpf() to load programs and create maps
CAP_NET_ADMIN   Send netlink messages to create interfaces, attach tc hooks,
                install routes, and change interface properties
CAP_SYS_ADMIN   Mount filesystems (the BPF filesystem), access /proc,
                and perform privileged operations not covered by the
                more specific capabilities above
```

A process that does not hold `CAP_BPF` receives `EPERM` (permission denied)
when it calls `bpf()`. A process that does not hold `CAP_NET_ADMIN` receives
`EPERM` when it sends netlink messages that modify network configuration. The
capability check happens inside the kernel before the operation is executed —
there is no way to bypass it from user space.

The Cilium DaemonSet requests these capabilities explicitly in its pod security
context:

```yaml
securityContext:
  capabilities:
    add:
      - NET_ADMIN
      - SYS_ADMIN
      - BPF
```

The cluster administrator grants these capabilities implicitly by running
`helm install cilium`. This is the single point of privilege escalation in the
entire Cilium installation. Everything that follows — loading eBPF programs,
attaching tc hooks, creating virtual ethernet pairs — flows from these three
capabilities being present on the Cilium agent process.

---

## Comparison with a kernel module

```
Property                  Kernel module              Cilium eBPF programs
────────────────────────  ─────────────────────────  ────────────────────────────────
Installation              insmod or modprobe          bpf() system call
Safety verification       None — runs as kernel code  Kernel verifier checks all paths
Crash risk                Can corrupt kernel memory   Verifier prevents this
Kernel version coupling   Must match kernel version   Stable ABI, works across versions
Requires reboot           Sometimes (on first load)   Never
Persists across process   Yes                         Yes (tc attachment + BPF_OBJ_PIN)
restart
Updated at runtime        Requires rmmod + insmod     bpf() replaces the program
                          (brief gap in coverage)     atomically with no gap
```

The verifier and the stable `bpf()` system call ABI are what make Cilium's
approach preferable to a kernel module for this use case. Cilium can be
installed, updated, and removed on a running node without touching the kernel
binary, without risking a kernel panic, and without requiring any kernel
build tooling on the node.
