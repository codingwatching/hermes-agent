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

## Option 2: Home-manager (persistent gateway service)

For running hermes-agent as a **user-level service** (Telegram/Discord/Slack bot with built-in cron scheduler) via [home-manager](https://github.com/nix-community/home-manager). Works on any Linux distribution with Nix — you don't need NixOS.

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

## What happens under the hood

On `home-manager switch`, the module's activation script runs:

1. Copies the hermes-agent source from the nix store to `~/.hermes-agent/app/`
2. Creates a Python 3.11 venv with `uv venv`
3. Installs all Python dependencies via `uv pip install -e ".[all]"`
4. Installs npm dependencies (agent-browser)
5. Creates `~/.hermes/{sessions,cron/output,logs,memories,skills}` directories
6. Writes a default `config.yaml` if missing

Then home-manager:
- Starts `hermes-agent-gateway.service` as a systemd user service
- Adds the `hermes` CLI wrapper to your PATH

Subsequent runs skip all of this unless the nix package changes (tracked via stamp file).

## Directory layout

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

## Customizing

```bash
$EDITOR ~/.hermes/config.yaml
```

Key settings:
- `model.default` — Which LLM to use (default: `anthropic/claude-opus-4.6`)
- `terminal.env_type` — Terminal backend: `local`, `docker`, `ssh`
- `toolsets` — Which tools to enable (default: all)

After editing, restart the service:

```bash
systemctl --user restart hermes-agent-gateway
```

## Updating

```bash
nix flake update hermes-agent --flake ~/.config/home-manager
home-manager switch
# Activation script re-copies source + reinstalls deps automatically
```

## Troubleshooting

```bash
# Gateway logs
journalctl --user -u hermes-agent-gateway -f

# Check CLI + deps
hermes doctor

# Restart gateway
systemctl --user restart hermes-agent-gateway

# Force reinstall deps (e.g. after manual venv corruption)
rm ~/.hermes-agent/app/.venv/.deps-installed
home-manager switch
```
