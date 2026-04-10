# CycleCloud Workspace for Slurm — Cluster-Init Projects

A collection of [cluster-init](https://learn.microsoft.com/azure/cyclecloud/how-to/cluster-init) projects for [Azure CycleCloud Workspace for Slurm](https://learn.microsoft.com/azure/cyclecloud/), providing automated installation and configuration of common HPC infrastructure components.

## Projects

| Project | Version | Description |
|---------|---------|-------------|
| [blobfuse2](projects/blobfuse2/) | 1.0.0 | Mount Azure Blob Storage via Blobfuse2 with auto-detected cache, MSI/key auth, and systemd integration |
| [cc-ooc-handler](projects/cc-ooc-handler/) | 1.0.0 | Handle Out-of-Capacity (OOC) scenarios with a Slurm `job_submit` Lua plugin for load-balanced partition routing |
| [cvmfs-eessi](projects/cvmfs-eessi/) | 1.0.0 | Install and configure CVMFS with EESSI support for scientific software access |
| [thinlinc](projects/thinlinc/) | 1.1.0 | Configure ThinLinc Web Access on compute nodes and optionally deploy as an Open OnDemand interactive app |

> **Note:** The `ldap-auth` project has been moved to [xpillons/cc-ldap-auth](https://github.com/xpillons/cc-ldap-auth).

## Usage

Each project follows the standard CycleCloud cluster-init structure:

```
<project>/
├── project.ini
├── README.md
└── specs/
    └── <spec>/
        └── cluster-init/
            ├── files/       # Configuration files and templates
            └── scripts/     # Numbered installation scripts (run in order)
```

### Adding a Project to a Cluster

Reference a project spec in your CycleCloud cluster template:

```ini
[cluster-init <project>:<spec>:<version>]
```

For example:

```ini
[cluster-init blobfuse2:default:1.0.0]
[cluster-init cvmfs-eessi:default:1.0.0]
[cluster-init thinlinc:default:1.1.0]
```

### Building and Uploading

```bash
cd projects/<project>
cyclecloud project build
cyclecloud project upload <locker>
```

## Contributing

Each project is self-contained with its own `README.md` documenting configuration options and usage details. Scripts are idempotent and safe to run multiple times.
