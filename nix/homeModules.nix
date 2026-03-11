# nix/homeModules.nix — Home-manager module for hermes-agent
{ inputs, ... }: {
  flake.homeManagerModules.default = { config, lib, pkgs, ... }:
    let
      cfg = config.services.hermes-agent;

      binPath = lib.makeBinPath (with pkgs; [
        python311 nodejs_20 ripgrep git openssh uv rsync coreutils ffmpeg
      ]);

      hermesWrapper = pkgs.writeShellScriptBin "hermes" ''
        export HERMES_HOME="${cfg.hermesHome}"
        export PATH="${cfg.stateDir}/app/.venv/bin:${binPath}:$PATH"
        exec "${cfg.stateDir}/app/.venv/bin/hermes" "$@"
      '';

    in {
      options.services.hermes-agent = {
        enable = lib.mkEnableOption "Hermes Agent AI assistant";

        package = lib.mkOption {
          type = lib.types.package;
          default = inputs.self.packages.${pkgs.system}.default;
          defaultText = lib.literalExpression "hermes-agent.packages.\${pkgs.system}.default";
          description = "The hermes-agent source bundle package.";
        };

        stateDir = lib.mkOption {
          type = lib.types.str;
          default = "${config.home.homeDirectory}/.hermes-agent";
          description = "Directory for hermes-agent state (source copy, venv).";
        };

        hermesHome = lib.mkOption {
          type = lib.types.str;
          default = "${config.home.homeDirectory}/.hermes";
          description = "Hermes config/sessions/memories directory.";
        };

        environmentFile = lib.mkOption {
          type = lib.types.str;
          default = "${config.home.homeDirectory}/.hermes/.env";
          description = "Path to environment file containing API keys.";
        };

        messagingCwd = lib.mkOption {
          type = lib.types.str;
          default = config.home.homeDirectory;
          description = "Working directory for gateway messaging.";
        };

        gateway = {
          enable = lib.mkEnableOption "Hermes Agent messaging gateway";
        };

        addToPATH = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Add hermes CLI wrapper to PATH via home.packages.";
        };
      };

      config = lib.mkIf cfg.enable {
        home.packages = lib.mkIf cfg.addToPATH [ hermesWrapper ];

        # Activation script: copy source, create venv, install deps
        home.activation.hermesAgentSetup = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          export PATH="${binPath}:$PATH"

          APP_DIR="${cfg.stateDir}/app"
          VENV_DIR="$APP_DIR/.venv"
          HERMES_HOME="${cfg.hermesHome}"
          STAMP_FILE="$APP_DIR/.nix-pkg-stamp"
          PKG_PATH="${cfg.package}"

          # Create hermes home structure
          mkdir -p "$HERMES_HOME"/{sessions,cron/output,logs,memories,skills}

          # Create default config.yaml if missing
          if [ ! -f "$HERMES_HOME/config.yaml" ]; then
            cat > "$HERMES_HOME/config.yaml" << 'YAML'
_config_version: 1
model:
  default: "anthropic/claude-opus-4.6"
terminal:
  env_type: "local"
YAML
          fi

          # Only re-copy source if package changed
          if [ -f "$STAMP_FILE" ] && [ "$(cat "$STAMP_FILE")" = "$PKG_PATH" ]; then
            echo "hermes-agent: package unchanged, skipping source copy."
          else
            echo "hermes-agent: copying source tree from Nix store..."
            mkdir -p "$APP_DIR"

            ${pkgs.rsync}/bin/rsync -a --delete \
              --exclude='.venv' \
              --exclude='node_modules' \
              "$PKG_PATH/share/hermes-agent/" "$APP_DIR/"

            chmod -R u+w "$APP_DIR"
            echo "$PKG_PATH" > "$STAMP_FILE"

            # Force reinstall when source changes
            rm -f "$VENV_DIR/.deps-installed"
          fi

          # Create venv if missing
          if [ ! -d "$VENV_DIR" ]; then
            echo "hermes-agent: creating Python venv..."
            ${pkgs.uv}/bin/uv venv "$VENV_DIR" --python ${pkgs.python311}/bin/python3
          fi

          # Install Python deps if needed
          if [ ! -f "$VENV_DIR/.deps-installed" ]; then
            echo "hermes-agent: installing Python dependencies..."
            VIRTUAL_ENV="$VENV_DIR" ${pkgs.uv}/bin/uv pip install -e "$APP_DIR[all]"

            if [ -d "$APP_DIR/mini-swe-agent" ]; then
              VIRTUAL_ENV="$VENV_DIR" ${pkgs.uv}/bin/uv pip install -e "$APP_DIR/mini-swe-agent"
            fi

            if [ -d "$APP_DIR/tinker-atropos" ]; then
              VIRTUAL_ENV="$VENV_DIR" ${pkgs.uv}/bin/uv pip install -e "$APP_DIR/tinker-atropos"
            fi

            touch "$VENV_DIR/.deps-installed"
          fi

          # Install npm deps if needed
          if [ -f "$APP_DIR/package.json" ] && [ ! -d "$APP_DIR/node_modules" ]; then
            echo "hermes-agent: installing npm dependencies..."
            cd "$APP_DIR"
            ${pkgs.nodejs_20}/bin/npm install --production
          fi
        '';

        # Gateway user service
        systemd.user.services.hermes-agent-gateway = lib.mkIf cfg.gateway.enable {
          Unit = {
            Description = "Hermes Agent messaging gateway";
            After = [ "network-online.target" ];
            Wants = [ "network-online.target" ];
            StartLimitIntervalSec = 300;
            StartLimitBurst = 10;
          };

          Service = {
            Type = "simple";
            WorkingDirectory = "${cfg.stateDir}/app";
            ExecStart = "${cfg.stateDir}/app/.venv/bin/hermes gateway run --replace";
            Restart = "on-failure";
            RestartSec = 15;
            Environment = [
              "HOME=${config.home.homeDirectory}"
              "HERMES_HOME=${cfg.hermesHome}"
              "MESSAGING_CWD=${cfg.messagingCwd}"
              "PATH=${cfg.stateDir}/app/.venv/bin:${binPath}"
            ];
            EnvironmentFile = cfg.environmentFile;
          };

          Install = {
            WantedBy = [ "default.target" ];
          };
        };
      };
    };
}
