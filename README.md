# synology-docker

> [!NOTE]
> An unofficial but battle‑tested way to update Docker Engine & Docker Compose on Synology NAS.
>
> Originally forked from [markdumay/synology-docker](https://github.com/markdumay/synology-docker)

![Last Commit][synology-docker-last-commit] ![Issues][synology-docker-issues] ![Pull Requests][synology-docker-pulls] ![License][synology-docker-license]

## Why this exists

Synology ships Docker or, as they call it in later versions "Container Manager"... but it's OLD. Really old.

This repo gives you a **repeatable, reversible, and reasonably safe** way to:

- Update Docker Engine on Synology to the latest
- Update Docker Compose
- Escape Synology’s legacy `db` log driver
- Roll back if something goes sideways

If you’re comfortable with SSH and `sudo`, this is for you.

> [!IMPORTANT]\
> **This is not supported by Synology.**
> You can absolutely break things if you ignore instructions. Always have backups.
> Once upgraded, The ContainerManager UI will no longer work reliably for managing containers or observing logs.

### DSM Version

Before using this, update to the most recent version of DSM that you can. That'll avoid many issues and will make sure the minor version of your kernel is up to date. I can't keep track of all of the older minor kernel versions for each platform, that would become unmanageable. Sometimes you'll need to download the latest DSM patch manually as it may not show as an automatic update for your model. Look for your latest DSM [here](https://www.synology.com/en-br/support/download)

### Nvidia users

If you use the Nvidia runtime, you may need to re‑run:

```bash
nvidia-ctk runtime configure
```

or restart the Nvidia driver **after** running this script.

### Portainer users (seriously, read this)

Portainer currently **persists the original logging driver** used when a container was created. This means:

- Containers created with the `db` logger will _stay broken_ after upgrade
- You **must recreate** them to switch to `local`

> [!TIP]
> 👉 **Fix your loggers before upgrading Docker** or you’ll spend hours recreating containers anyway.

## What this script actually does

At a high level:

1. Downloads official Docker, Compose & Buildx binaries
2. Backs up your existing Docker install
3. Stops Docker safely
4. Replaces binaries & config
5. Restarts Docker

Everything is scripted. Nothing is magic. Rollbacks are built‑in.

### What you end up with (vs. Docker's Ubuntu packages)

DSM has no `apt`/`dpkg`, so the `.deb` packages Docker recommends for Ubuntu can't be installed directly. Instead the
script installs the **same official static binaries** those packages contain, so the result is equivalent to:

| Ubuntu package          | What gets installed on the NAS                                                              |
| ----------------------- | ------------------------------------------------------------------------------------------- |
| `docker-ce`             | `dockerd`, `docker-init`, `docker-proxy` from the official static tarball                   |
| `docker-ce-cli`         | `docker` from the same tarball                                                              |
| `containerd.io`         | `containerd`, `containerd-shim-runc-v2`, `ctr`, `runc` from the same tarball                |
| `docker-compose-plugin` | `docker compose` CLI plugin (also kept as standalone `docker-compose` for backwards compat) |
| `docker-buildx-plugin`  | `docker buildx` CLI plugin                                                                  |

Engine binaries go to the ContainerManager/Docker package `bin` folder. CLI plugins go to
`/usr/local/lib/docker/cli-plugins`, the well-known path the Docker CLI searches, so `docker compose` and
`docker buildx` work for all users. Plugins are included in backups and restored by `restore`.

### Networking fixes applied to `start-stop-status`

Every `update` (and `only_script`) inserts a small block into the package's `start-stop-status` that runs after
dockerd is up:

- **FORWARD chain**: sets the policy to `ACCEPT` and jumps to `DOCKER-FORWARD`, so published ports stay reachable
  after a clean boot.
- **NAT MASQUERADE fallback**: DSM firewall reloads flush the MASQUERADE rules dockerd adds to `nat POSTROUTING`,
  leaving containers without outbound internet. The script adds a persistent catch-all rule to the DSM-managed
  `DEFAULT_POSTROUTING` chain (skipped when that chain does not exist, e.g. DSM firewall disabled):

  ```bash
  iptables -t nat -A DEFAULT_POSTROUTING -s 172.16.0.0/12 ! -d 172.16.0.0/12 -j MASQUERADE
  ```

  `172.16.0.0/12` covers Docker's default address pool. If your networks use custom subnets outside that range,
  pass `--masq-subnet CIDR` (e.g. `--masq-subnet 192.168.100.0/22`). `fix_ipforward.sh` accepts the same option.

## Installation

SSH into your NAS and clone the repo:

```bash
git clone https://github.com/telnetdoogie-labs/synology-docker
cd synology-docker
```

## 🚀 First‑time upgrade (do this once, carefully)

> [!NOTE]
> **TL;DR:** Fix logging → recreate containers → upgrade Docker

### Step 1: Switch Docker’s default log driver

```bash
sudo ./syno_docker_update.sh logger
```

This:

- Sets Docker’s default log driver to `local`
- Restarts Docker

Then check which containers are _still_ using `db`:

```bash
./syno_docker_list_containers.sh
```

Example output:

```
Container            Compose_Location                               Logger
-------------------  ---------------------------------------------- -------
/transmission        /volume1/docker/downloader/docker-compose.yml  db
/jellyfin            /volume1/docker/jellyfin/docker-compose.yml    db
/dozzle              /volume1/docker/dozzle/docker-compose.yml      local
```

### Step 2: Recreate containers still using `db`

For **each** compose‑managed container using `db`:

```bash
cd /volume1/docker/jellyfin
docker-compose up -d --force-recreate
```

Re‑run `syno_docker_list_containers.sh` until **everything** says `local`.

> Containers created via `docker run` will show a _best‑guess_ recreate command. Verify it before running.

### Step 3: Upgrade Docker & Compose

```bash
sudo ./syno_docker_update.sh update
```

If you did the logger step correctly, containers should come back automatically.

## 🔁 Future updates (easy mode)

Once you’ve crossed the logging hurdle, updates are simple:

```bash
cd synology-docker
git pull
sudo ./syno_docker_update.sh update
```

## Usage

```bash
sudo ./syno_docker_update.sh [OPTIONS] COMMAND
```

### Commands

| Command         | Description                        |
| --------------- | ---------------------------------- |
| `backup`        | Backup Docker binaries & config    |
| `download PATH` | Download Docker & Compose binaries |
| `install PATH`  | Install from downloaded files      |
| `restore`       | Restore from backup                |
| `logger`        | Update logging driver only         |
| `update`        | Full backup + update               |

## Options

| Option              | Description               |
| ------------------- | ------------------------- |
| `--docker VERSION`  | Target Docker version     |
| `--compose VERSION` | Target Compose version    |
| `--buildx VERSION`  | Target Buildx version     |
| `--masq-subnet CIDR` | Source subnet for the fallback NAT MASQUERADE rule (default `172.16.0.0/12`) |
| `--target NAME`     | `all`, `engine`, `compose`, `buildx`, or `driver` |
| `--backup NAME`     | Backup file name          |
| `--force`           | Skip compatibility checks |
| `--stage`           | Download only, no install |

## Contributing

PRs are **VERY** welcome here. Many of the recent updates have been contributed by users just like you.

1. Open an [Issue](https://github.com/telnetdoogie-labs/synology-docker/issues)
2. [Fork the repo](https://github.com/telnetdoogie-labs/synology-docker/fork)
3. Make and test your change on real hardware
4. Submit a PR back to this repo, and link with a comment to the Issue you created.
5. Provide details on what you did, what you've tested it on, and the results of those tests.

## Credits

- Original work by [@markdumay](https://github.com/markdumay)
- Extensive testing by [@mrmuiz](https://github.com/mrmuiz)
- Kernel 5.x runc issue / resolution and additional repo contributions and maintenance by [@bslatyer](https://github.com/bslatyer)
- Network‑pain endurance by [@CodeNodeNomad](https://github.com/CodeNodeNomad)
- Awesome IP Forward rules fix and AppArmor update for v29+ by [@Salvora](https://github.com/Salvora)
- AppArmor update / fix by [@Auddis](https://github.com/Auddis)

## Special Thanks

- [@bslatyer](https://github.com/bslatyer) for repo maintenance and proactive stewardship and co-ownership
- **Marius** @ [MariusHosting](https://mariushosting.com) for linking to the repo from his [August 2026 post](https://mariushosting.com/synology-new-docker-version-24-0-2-1706/)

## Origin

Forked from [https://github.com/markdumay/synology-docker](https://github.com/markdumay/synology-docker)

[synology-docker-last-commit]: https://img.shields.io/github/last-commit/telnetdoogie/synology-docker.svg
[synology-docker-issues]: https://img.shields.io/github/issues/telnetdoogie/synology-docker.svg
[synology-docker-pulls]: https://img.shields.io/github/issues-pr-raw/telnetdoogie/synology-docker.svg
[synology-docker-license]: https://img.shields.io/github/license/telnetdoogie/synology-docker.svg
