# ThinLinc Web Access Project

This project provides automated configuration of [ThinLinc](https://www.cendio.com/thinlinc/) Web Access for Azure CycleCloud clusters, with optional integration into [Open OnDemand](https://openondemand.org/) (OOD) as an interactive app.

## Prerequisites

- Azure CycleCloud cluster with ThinLinc already installed (`/opt/thinlinc`)
- For the OOD spec: Open OnDemand installed with apps directory at `/var/www/ood/apps/sys`

## Specs

### `default` — ThinLinc Web Access Configuration

Configures ThinLinc Web Access on compute nodes where ThinLinc is already installed.

**Scripts:**

| Script | Description |
|--------|-------------|
| `00_prereqs.sh` | Disables firewalld and SELinux to allow ThinLinc web traffic |
| `01_configure_tlwebaccess.sh` | Validates ThinLinc installation, configures PAM authentication, web access port, vsmagent hostname, xsession, and restarts the tlwebaccess service |

**What `01_configure_tlwebaccess.sh` does:**

- Validates that ThinLinc is installed at `/opt/thinlinc`
- Configures `pam_tlpasswd.so` in `/etc/pam.d/sshd` for password authentication
- Downloads and installs a custom xsession from the [ood-thinlinc](https://github.com/cendio/ood-thinlinc) repository
- Sets the web access listen port (default: 443)
- Sets `vsmagent/agent_hostname` to `$HOSTNAME` for correct URL generation behind a reverse proxy
- Restarts the `tlwebaccess` service

### `ood` — Open OnDemand Interactive App

Installs and configures ThinLinc as an Open OnDemand interactive application using the [cendio/ood-thinlinc](https://github.com/cendio/ood-thinlinc) project.

**Scripts:**

| Script | Description |
|--------|-------------|
| `01_install_app.sh` | Clones the ood-thinlinc app, copies custom `form.yml` and `submit.yml.erb` configuration files |

**Configuration files:**

| File | Description |
|------|-------------|
| `form.yml` | OOD form definition — cluster, queue, hours, and GPU count |
| `submit.yml.erb` | Slurm job submission template — single exclusive node with optional GPU allocation |

## Project Structure

```
thinlinc/
├── project.ini
├── README.md
└── specs/
    ├── default/
    │   └── cluster-init/
    │       ├── files/
    │       │   └── common.sh          # Shared logging and utility functions
    │       └── scripts/
    │           ├── 00_prereqs.sh
    │           └── 01_configure_tlwebaccess.sh
    └── ood/
        └── cluster-init/
            ├── files/
            │   ├── form.yml
            │   └── submit.yml.erb
            └── scripts/
                └── 01_install_app.sh
```

## CycleCloud Integration

Add this project to your CycleCloud cluster template:

```ini
[cluster-init thinlinc:default:1.1.0]
  # Runs on compute nodes where ThinLinc is installed

[cluster-init thinlinc:ood:1.1.0]
  # Runs on the OOD server node
```

## Logging

All scripts log to `/var/log/thinlinc-webaccess-config.log` with timestamped entries. Operations are idempotent and safe to run multiple times.
