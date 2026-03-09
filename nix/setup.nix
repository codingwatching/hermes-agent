# nix/setup.nix — Bootstrap script: `nix run github:NousResearch/hermes-agent#setup`
{ inputs, ... }: {
  perSystem = { pkgs, system, ... }:
    let
      flakeUrl = "github:NousResearch/hermes-agent";
      templateName = "home-manager";

      setup = pkgs.writeShellApplication {
        name = "hermes-setup";
        runtimeInputs = with pkgs; [ coreutils gnused git nix ];
        text = ''
          set -euo pipefail

          # --- Colors ---
          bold=$'\e[1m'
          cyan=$'\e[36m'
          green=$'\e[32m'
          yellow=$'\e[33m'
          red=$'\e[31m'
          reset=$'\e[0m'

          info()    { echo "''${cyan}▸''${reset} $*"; }
          ok()      { echo "''${green}✓''${reset} $*"; }
          warn()    { echo "''${yellow}⚠''${reset} $*"; }
          err()     { echo "''${red}✗''${reset} $*"; }
          ask()     { printf "''${bold}%s''${reset} " "$1"; }

          echo
          echo "''${bold}  Hermes Agent — Nix Setup''${reset}"
          echo "  ─────────────────────────"
          echo

          # --- Detect system ---
          ARCH="$(uname -m)"
          OS="$(uname -s)"
          case "''${ARCH}-''${OS}" in
            x86_64-Linux)   NIX_SYSTEM="x86_64-linux" ;;
            aarch64-Linux)  NIX_SYSTEM="aarch64-linux" ;;
            arm64-Darwin)   NIX_SYSTEM="aarch64-darwin" ;;
            x86_64-Darwin)  NIX_SYSTEM="x86_64-darwin" ;;
            *) err "Unsupported platform: ''${ARCH}-''${OS}"; exit 1 ;;
          esac

          USERNAME="$(whoami)"
          HOMEDIR="$HOME"
          HM_DIR="$HOME/.config/home-manager"
          HERMES_HOME="$HOME/.hermes"

          info "Platform: ''${NIX_SYSTEM}"
          info "User: ''${USERNAME}"
          echo

          # --- Check for existing home-manager config ---
          if [ -f "''${HM_DIR}/flake.nix" ]; then
            warn "Existing home-manager config found at ''${HM_DIR}/flake.nix"
            echo
            echo "  Add these to your existing config:"
            echo
            echo "  ''${bold}flake.nix inputs:''${reset}"
            echo "    hermes-agent.url = \"${flakeUrl}\";"
            echo
            echo "  ''${bold}modules list:''${reset}"
            echo "    hermes-agent.homeManagerModules.default"
            echo
            echo "  ''${bold}home.nix:''${reset}"
            echo "    services.hermes-agent = {"
            echo "      enable = true;"
            echo "      gateway.enable = true;"
            echo "    };"
            echo
            ask "Overwrite with fresh config? [y/N]"
            read -r answer
            if [[ ! "''${answer}" =~ ^[Yy] ]]; then
              info "Keeping existing config. Add the module manually and run: home-manager switch"
              exit 0
            fi
          fi

          # --- Scaffold home-manager config ---
          info "Creating home-manager config at ''${HM_DIR}/"
          mkdir -p "''${HM_DIR}"

          cat > "''${HM_DIR}/flake.nix" << FLAKE
          {
            description = "Home-manager configuration with Hermes Agent";

            inputs = {
              nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
              home-manager = {
                url = "github:nix-community/home-manager";
                inputs.nixpkgs.follows = "nixpkgs";
              };
              hermes-agent.url = "${flakeUrl}";
            };

            outputs = { nixpkgs, home-manager, hermes-agent, ... }: {
              homeConfigurations."''${USERNAME}" = home-manager.lib.homeManagerConfiguration {
                pkgs = nixpkgs.legacyPackages.''${NIX_SYSTEM};
                modules = [
                  hermes-agent.homeManagerModules.default
                  ./home.nix
                ];
              };
            };
          }
          FLAKE

          # Remove leading whitespace from heredoc
          sed -i 's/^          //' "''${HM_DIR}/flake.nix"

          cat > "''${HM_DIR}/home.nix" << HOME
          { config, pkgs, ... }: {
            home.username = "''${USERNAME}";
            home.homeDirectory = "''${HOMEDIR}";
            home.stateVersion = "24.11";
            programs.home-manager.enable = true;

            services.hermes-agent = {
              enable = true;
              gateway.enable = true;
            };
          }
          HOME

          sed -i 's/^          //' "''${HM_DIR}/home.nix"

          ok "Config written"
          echo

          # --- API keys ---
          info "Configuring API keys"
          echo "  Press Enter to skip any key."
          echo
          mkdir -p "''${HERMES_HOME}"

          ENV_FILE="''${HERMES_HOME}/.env"

          # Preserve existing keys if file exists
          if [ -f "''${ENV_FILE}" ]; then
            ok "Existing ''${ENV_FILE} found — keeping it"
          else
            touch "''${ENV_FILE}"
            chmod 600 "''${ENV_FILE}"

            # LLM provider
            ask "OpenRouter API key (https://openrouter.ai/keys):"
            read -r key
            if [ -n "''${key}" ]; then
              echo "OPENROUTER_API_KEY=''${key}" >> "''${ENV_FILE}"
              ok "Saved"
            fi

            echo

            # Telegram
            ask "Telegram bot token (from @BotFather):"
            read -r key
            if [ -n "''${key}" ]; then
              echo "TELEGRAM_BOT_TOKEN=''${key}" >> "''${ENV_FILE}"
              ask "Telegram allowed user IDs (comma-separated):"
              read -r ids
              if [ -n "''${ids}" ]; then
                echo "TELEGRAM_ALLOWED_USERS=''${ids}" >> "''${ENV_FILE}"
              fi
              ok "Saved"
            fi

            echo

            # Discord
            ask "Discord bot token (optional):"
            read -r key
            if [ -n "''${key}" ]; then
              echo "DISCORD_BOT_TOKEN=''${key}" >> "''${ENV_FILE}"
              ok "Saved"
            fi

            echo
            ok "Keys written to ''${ENV_FILE}"
          fi

          echo

          # --- Enable linger (Linux only) ---
          if [ "''${OS}" = "Linux" ]; then
            if loginctl show-user "''${USERNAME}" --property=Linger 2>/dev/null | grep -q "Linger=yes"; then
              ok "loginctl linger already enabled"
            else
              info "Enabling loginctl linger (needed for user services to survive logout)"
              if sudo loginctl enable-linger "''${USERNAME}"; then
                ok "Linger enabled"
              else
                warn "Could not enable linger. Run manually: sudo loginctl enable-linger ''${USERNAME}"
              fi
            fi
            echo
          fi

          # --- Activate ---
          info "Activating home-manager (first run installs deps — this takes a few minutes)..."
          echo
          if nix run github:nix-community/home-manager -- switch --flake "''${HM_DIR}#''${USERNAME}"; then
            echo
            ok "Setup complete!"
            echo
            echo "  ''${bold}Gateway:''${reset} systemctl --user status hermes-agent-gateway"
            echo "  ''${bold}Logs:''${reset}    journalctl --user -u hermes-agent-gateway -f"
            echo "  ''${bold}CLI:''${reset}     hermes"
            echo "  ''${bold}Doctor:''${reset}  hermes doctor"
            echo "  ''${bold}Config:''${reset}  ''${HM_DIR}/home.nix"
            echo
          else
            err "home-manager switch failed. Check the output above."
            echo "  You can retry with: nix run github:nix-community/home-manager -- switch --flake ''${HM_DIR}#''${USERNAME}"
            exit 1
          fi
        '';
      };
    in {
      apps.setup = {
        type = "app";
        program = "${setup}";
      };
    };
}
