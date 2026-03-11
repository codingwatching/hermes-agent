# Nix Setup Guide for Hermes Agent

## Prerequisites

- Nix with flakes enabled (we recommend [Determinate Nix](https://install.determinate.systems) which enables flakes by default)
- Internet access (for initial Python/npm dependency installation)
- API keys for the services you want to use (at minimum: OpenRouter)

## Option 1: Development (nix develop)

For hacking on hermes-agent locally:

```bash
git clone --recurse-submodules https://github.com/NousResearch/hermes-agent.git
cd hermes-agent
nix develop
# Shell automatically:
#   - Creates .venv with Python 3.11
#   - Installs all Python deps via uv
#   - Installs npm deps (agent-browser)
#   - Puts ripgrep, git, node on PATH

# Configure your API keys
hermes setup

# Start chatting
hermes
```

### Using direnv (recommended)

If you have [direnv](https://direnv.net/) installed, the included `.envrc` will
automatically activate the dev shell when you `cd` into the repo:

```bash
cd hermes-agent
direnv allow    # one-time approval

# From now on, entering the directory activates the environment automatically.
# On repeat entry, the stamp file check skips dependency installation (~instant).
```

## Option 2: Server Deployment (NixOS Module)

For running Hermes Agent as a persistent service (Telegram/Discord/Slack bot with built-in cron scheduler).

### Step 1: Add the flake input to your NixOS configuration

```nix
# flake.nix (your system flake)
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    hermes-agent = {
      url = "github:NousResearch/hermes-agent";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, hermes-agent, ... }: {
    nixosConfigurations.my-server = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        hermes-agent.nixosModules.default
      ];
    };
  };
}
```

### Step 2: Create your secrets file

Store API keys in a file that will be loaded as environment variables. Use your preferred secrets manager (sops-nix, agenix, or a plain file with restricted permissions).

```bash
# /etc/hermes/secrets.env (chmod 600, owned by root)
OPENROUTER_API_KEY=sk-or-v1-xxxxxxxxxxxxx

# Telegram bot (get token from @BotFather, get user ID from @userinfobot)
TELEGRAM_BOT_TOKEN=123456789:ABCdefGHIjklMNOpqrSTUvwxYZ
TELEGRAM_ALLOWED_USERS=123456789

# Discord bot (get from Discord Developer Portal)
# DISCORD_BOT_TOKEN=MTIz...
# DISCORD_ALLOWED_USERS=123456789012345678

# Optional tool API keys (tools auto-disable if key is missing)
# FIRECRAWL_API_KEY=fc-xxxxxxxxxxxxx
# BROWSERBASE_API_KEY=bb-xxxxxxxxxxxxx
# BROWSERBASE_PROJECT_ID=proj-xxxxxxxxxxxxx
# FAL_KEY=xxxxxxxxxxxxx
# NOUS_API_KEY=xxxxxxxxxxxxx
```

### Step 3: Configure the NixOS module

```nix
# configuration.nix
{ config, pkgs, ... }:
{
  services.hermes-agent = {
    enable = true;

    # Path to your secrets file
    environmentFile = "/etc/hermes/secrets.env";

    # Enable the messaging gateway (includes cron scheduler)
    gateway.enable = true;

    # Optional overrides:
    # user = "hermes";               # default
    # group = "hermes";              # default
    # stateDir = "/var/lib/hermes";  # default
  };
}
```

### Step 4: Deploy

```bash
sudo nixos-rebuild switch
```

### Step 5: Verify

```bash
# Check setup completed (runs on first boot, installs Python/npm deps)
systemctl status hermes-agent-setup

# Check gateway is running (cron scheduler runs inside the gateway)
systemctl status hermes-agent-gateway
journalctl -u hermes-agent-gateway -f

# Test: send a message to your Telegram bot
```

## What happens under the hood

1. **hermes-agent-setup.service** (runs once, re-runs on package updates):
   - Copies the hermes-agent source to `/var/lib/hermes/app/`
   - Creates a Python 3.11 venv at `/var/lib/hermes/app/.venv`
   - Installs all Python dependencies via `uv pip install`
   - Installs npm dependencies (agent-browser for browser automation)
   - Creates the `~/.hermes/` config structure
   - Has `TimeoutStartSec = 300` to allow for slow network installs

2. **hermes-agent-gateway.service** (persistent):
   - Runs the messaging gateway (Telegram, Discord, Slack, WhatsApp)
   - Includes the cron scheduler (checks for due tasks every 60 seconds)
   - Auto-restarts on failure (with 15s delay, up to 10 retries per 5 minutes)
   - Reads API keys from your `environmentFile`
   - Sets `MESSAGING_CWD` to the state directory

## Directory Layout on NixOS

```
/var/lib/hermes/                  # State directory (writable)
├── app/                          # Source tree copy
│   ├── .venv/                    # Python virtual environment
│   ├── node_modules/             # npm dependencies
│   ├── skills/                   # Knowledge documents
│   ├── mini-swe-agent/           # Terminal backend
│   ├── tinker-atropos/           # RL training
│   └── ...                       # Full source tree
└── .hermes/                      # User config & data
    ├── config.yaml               # Agent configuration
    ├── sessions/                 # Messaging sessions
    ├── cron/                     # Scheduled jobs
    │   ├── jobs.json
    │   └── output/
    └── logs/                     # Session logs
```

## Customizing the Agent

Edit the config file on the server:

```bash
sudo -u hermes nano /var/lib/hermes/.hermes/config.yaml
```

Key settings:
- `model.default` — Which LLM to use (default: `anthropic/claude-opus-4.6`)
- `terminal.env_type` — Terminal backend: `local`, `docker`, `ssh`
- `toolsets` — Which tools to enable (default: all)
- `compression` — Context window management settings
- `agent.max_turns` — Max tool-calling iterations per conversation

After editing, restart the services:

```bash
sudo systemctl restart hermes-agent-gateway
```

## Updating

When a new version of hermes-agent is released:

```bash
# Update the flake input
nix flake update hermes-agent

# Rebuild
sudo nixos-rebuild switch

# The setup service will automatically re-run and update dependencies
```

## Troubleshooting

```bash
# View gateway logs (includes cron output)
journalctl -u hermes-agent-gateway -f

# View setup logs (dep installation)
journalctl -u hermes-agent-setup

# Run hermes doctor interactively as the service user (with correct env vars)
sudo -u hermes bash -c 'source /var/lib/hermes/app/.venv/bin/activate && HERMES_HOME=/var/lib/hermes/.hermes hermes doctor'

# Check which tools are available
sudo -u hermes bash -c 'source /var/lib/hermes/app/.venv/bin/activate && HERMES_HOME=/var/lib/hermes/.hermes hermes status'
```

## Non-Flake NixOS (builtins.getFlake)

If your NixOS system uses a traditional `configuration.nix` (not a flake), you can still use the module via `builtins.getFlake`. This requires `nix.settings.experimental-features` to include `"flakes"`.

```nix
# /etc/nixos/configuration.nix
let
  hermes-agent = builtins.getFlake "github:NousResearch/hermes-agent";
in
{
  imports = [
    ./hardware-configuration.nix
    hermes-agent.nixosModules.default
  ];

  services.hermes-agent = {
    enable = true;
    environmentFile = "/etc/hermes/secrets.env";
    gateway.enable = true;
  };

  # ... rest of your config
}
```

To update: run `sudo nix flake update --flake github:NousResearch/hermes-agent` then `sudo nixos-rebuild switch`.

## Option 3: Home-manager (any Linux with Nix)

For running hermes-agent as a **user-level service** via [home-manager](https://github.com/nix-community/home-manager). This works on any Linux distribution with Nix — you don't need NixOS.

> This assumes you already have home-manager set up. If you don't, see the [home-manager docs](https://nix-community.github.io/home-manager/) first.

### Step 1: Add the flake input

```nix
# ~/.config/home-manager/flake.nix (or wherever your HM flake lives)
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    hermes-agent.url = "github:NousResearch/hermes-agent";
  };

  outputs = { nixpkgs, home-manager, hermes-agent, ... }: {
    homeConfigurations."your-username" = home-manager.lib.homeManagerConfiguration {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      modules = [
        hermes-agent.homeManagerModules.default
        ./home.nix
      ];
    };
  };
}
```

### Step 2: Enable in home.nix

```nix
# home.nix
{
  services.hermes-agent = {
    enable = true;
    gateway.enable = true;

    # All options with defaults:
    # stateDir = "~/.hermes-agent";       # source copy + venv
    # hermesHome = "~/.hermes";           # config, sessions, memories
    # environmentFile = "~/.hermes/.env"; # API keys
    # messagingCwd = "~";                 # gateway working directory
    # addToPATH = true;                   # adds `hermes` CLI to PATH
  };
}
```

### Step 3: API keys

```bash
mkdir -p ~/.hermes
cat > ~/.hermes/.env << 'EOF'
OPENROUTER_API_KEY=sk-or-v1-xxxxxxxxxxxxx
TELEGRAM_BOT_TOKEN=123456789:ABCdefGHIjklMNOpqrSTUvwxYZ
TELEGRAM_ALLOWED_USERS=123456789
EOF
chmod 600 ~/.hermes/.env
```

### Step 4: Enable linger + activate

```bash
# Lets user services survive logout
sudo loginctl enable-linger $USER

# Activate (first run: ~2-3 min to install Python/npm deps)
home-manager switch
```

### Step 5: Verify

```bash
systemctl --user status hermes-agent-gateway
journalctl --user -u hermes-agent-gateway -f
hermes doctor
```

### Home-manager directory layout

```
~/.hermes-agent/                     # State directory
├── app/                             # Source tree copy
│   ├── .venv/                       # Python virtual environment
│   ├── .nix-pkg-stamp              # Tracks nix package version
│   └── ...
~/.hermes/                           # Config & data
├── .env                             # API keys
├── config.yaml                      # Agent configuration
├── sessions/                        # Messaging sessions
├── memories/                        # Agent memories
├── skills/                          # Knowledge documents
├── cron/                            # Scheduled jobs
└── logs/                            # Session logs
```

### Updating (home-manager)

```bash
nix flake update hermes-agent --flake ~/.config/home-manager
home-manager switch
# Activation script re-copies source + reinstalls deps automatically
```

---

## Using with sops-nix (recommended for secrets)

```nix
{
  sops.secrets."hermes-agent-env" = {
    sopsFile = ./secrets/hermes.yaml;
    format = "yaml";
  };

  services.hermes-agent = {
    enable = true;
    environmentFile = config.sops.secrets."hermes-agent-env".path;
    gateway.enable = true;
  };
}
```

## Using with agenix

```nix
{
  age.secrets.hermes-env.file = ./secrets/hermes.env.age;

  services.hermes-agent = {
    enable = true;
    environmentFile = config.age.secrets.hermes-env.path;
    gateway.enable = true;
  };
}
```
