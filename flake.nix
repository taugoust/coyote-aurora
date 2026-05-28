{
  description = "Coyote Aurora 64B/66B loopback example";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
    coyote = {
      url = "github:taugoust/Coyote";
      flake = false;
    };
    coyote-nix.url = "git+ssh://git@github.com/TUM-DSE/coyote-nix.git";
    coyote-nix.inputs.nixpkgs.follows = "nixpkgs";
    doctor-cluster-xilinx.url = "git+ssh://git@github.com/TUM-DSE/doctor-cluster-xilinx.git";
    xdb.url = "github:taugoust/xdb";
  };

  outputs =
    inputs@{
      nixpkgs,
      flake-utils,
      coyote,
      xdb,
      ...
    }:
    let
      coyoteNix = inputs."coyote-nix";
      doctorClusterXilinx = inputs."doctor-cluster-xilinx";
      linuxSystems = builtins.filter (
        system: builtins.match ".*-linux" system != null
      ) flake-utils.lib.defaultSystems;
    in
    flake-utils.lib.eachSystem linuxSystems (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        lib = pkgs.lib;
        isX86_64 = pkgs.stdenv.hostPlatform.isx86_64;
        coyoteRoot = coyote;
        doctor = doctorClusterXilinx.lib.mkXilinxContext { inherit pkgs system; };
        xilinxShareRoot = doctor.xilinxShareRoot;
        driverKernels = doctor.driverKernels;

        tools = coyoteNix.lib.mkTools {
          inherit pkgs coyoteRoot xilinxShareRoot;
          platforms = linuxSystems;
        };
        mkApp = coyoteNix.lib.mkApp;

        hwSource = lib.fileset.toSource {
          root = ./hw;
          fileset = lib.fileset.unions [
            ./hw/CMakeLists.txt
            ./hw/src
          ];
        };

        auroraHost = pkgs.stdenv.mkDerivation {
          pname = "aurora-loopback-host";
          version = "0.1.0";
          src = ./sw;

          nativeBuildInputs = with pkgs; [
            cmake
            gnumake
            pkg-config
            patchelf
          ];
          buildInputs = with pkgs; [ boost ];

          COYOTE_ROOT = coyoteRoot;
          cmakeFlags = [
            "-DCMAKE_POLICY_VERSION_MINIMUM=3.10"
            "-DCMAKE_POLICY_DEFAULT_CMP0167=OLD"
          ]
          ++ lib.optionals (!isX86_64) [ "-DEN_AVX=0" ];

          installPhase = ''
            runHook preInstall

            mkdir -p $out/bin $out/lib $out/libexec
            install -m755 test $out/libexec/aurora-loopback

            cat > $out/bin/aurora-loopback <<EOF
            #!${pkgs.runtimeShell}
            set -euo pipefail

            # Coyote uses Boost interprocess named mutexes backed by /dev/shm/sem.*.
            # Make stale mutexes owned by this user shareable and create future ones
            # with permissive permissions for shared lab machines.
            for sem in /dev/shm/sem.mutex_dev_* /dev/shm/sem.reconfig_mtx; do
              [ -e "\$sem" ] || continue
              if [ -O "\$sem" ]; then
                chmod a+rw "\$sem" 2>/dev/null || true
              fi
            done
            umask 000
            exec $out/libexec/aurora-loopback "\$@"
            EOF
            chmod +x $out/bin/aurora-loopback

            copied=0
            while IFS= read -r -d $'\0' lib; do
              cp -d "$lib" $out/lib/
              copied=$((copied + 1))
            done < <(find . \( -type f -o -type l \) -path '*/coyote/*.so*' -print0)

            if [ "$copied" -eq 0 ]; then
              echo "ERROR: no Coyote shared libraries were found under the build tree." >&2
              exit 1
            fi

            lib_path="$out/lib:${
              lib.makeLibraryPath [
                pkgs.boost
                pkgs.stdenv.cc.cc
              ]
            }"
            patchelf --set-rpath "$lib_path" $out/libexec/aurora-loopback

            for so in $out/lib/*.so*; do
              [ -e "$so" ] || continue
              if [ -f "$so" ]; then
                patchelf --set-rpath "$lib_path" "$so" || true
              fi
            done

            runHook postInstall
          '';

          meta = {
            description = "Host control app for the Coyote Aurora loopback example";
            mainProgram = "aurora-loopback";
            platforms = linuxSystems;
          };
        };

        auroraHwPackages = lib.optionalAttrs isX86_64 (
          coyoteNix.lib.mkCoyoteBoardPackages {
            inherit
              pkgs
              tools
              coyoteRoot
              hwSource
              xilinxShareRoot
              ;
            xilinxShell = doctor.xilinxShell;
            pnamePrefix = "aurora-loopback";
            projectName = "example_14_aurora_loopback";
            boards = {
              u280 = {
                inherit (doctor.boards.u280) xilinxVersion simXilinxVersion;
              };
            };
          }
        );

        coyoteDriverPackages = lib.optionalAttrs isX86_64 (
          coyoteNix.lib.mkCoyoteDriverPackages {
            inherit pkgs coyoteRoot driverKernels;
            inherit (doctor) targetPlatforms;
          }
        );

        packagePath = packageName: path: "${auroraHwPackages.${packageName}}/${path}";

        xdbPackage = xdb.packages.${system}.default;
        mkXdbWrapper =
          simXilinxVersion:
          pkgs.writeShellApplication {
            name = "xdb";
            text = ''
              for arg in "$@"; do
                if [ "$arg" = "sim" ]; then
                  export COYOTE_NIX_XILINX_VERSION="${simXilinxVersion}"
                  break
                fi
              done
              exec ${xdbPackage}/bin/xdb "$@"
            '';
          };

        compileCommandsHook = ''
          ${doctor.hostFpgaEnvShellFragment}

          if [ "''${AURORA_SKIP_AUTO_COMPILE_COMMANDS:-0}" != "1" ]; then
            project_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
            sw_dir="$project_root/sw"

            if [ -f "$sw_dir/CMakeLists.txt" ]; then
              project_id="$(printf '%s' "$project_root" | sha256sum | awk '{print substr($1, 1, 16)}')"
              cache_home="''${XDG_CACHE_HOME:-''${HOME:-/tmp}/.cache}"
              compile_root="''${AURORA_COMPILE_COMMANDS_ROOT:-$cache_home/aurora-loopback/$project_id}"
              build_dir="$compile_root/sw"
              log_path="$build_dir/cmake-configure.log"

              mkdir -p "$build_dir"

              if ! cmake -S "$sw_dir" -B "$build_dir" \
                -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
                -DCMAKE_POLICY_VERSION_MINIMUM=3.10 \
                -DCMAKE_POLICY_DEFAULT_CMP0167=OLD >"$log_path" 2>&1; then
                echo "aurora-loopback: CMake configure failed; see $log_path" >&2
                tail -n 40 "$log_path" >&2 || true
                exit 1
              fi

              if [ -f "$build_dir/compile_commands.json" ]; then
                ln -sfn "$build_dir/compile_commands.json" "$project_root/compile_commands.json"
              fi
            fi
          fi
        '';

        mkXilinxDevShell =
          {
            board,
            fpgaPackage,
            fpgaArtifact,
            simPackageProject,
            simPackageRuntime,
            simSession,
            simWorkspaceSuffix ? board.board,
            simProjectName ? "example_14_aurora_loopback.xpr",
          }:
          coyoteNix.lib.mkCoyoteDevShell {
            inherit
              pkgs
              tools
              coyoteRoot
              board
              ;
            withXilinx = true;
            fpgaPackage = fpgaPackage;
            fpgaArtifact = fpgaArtifact;
            packages = [ (mkXdbWrapper board.simXilinxVersion) ];
            sim = {
              workspaceSuffix = simWorkspaceSuffix;
              packageProject = simPackageProject;
              packageRuntime = simPackageRuntime;
              projectName = simProjectName;
              simset = "sim_1";
              top = "tb_user";
              mode = "behavioral";
              session = simSession;
            };
            shellHook = compileCommandsHook;
          };
      in
      {
        devShells = {
          default = coyoteNix.lib.mkCoyoteDevShell {
            inherit pkgs tools coyoteRoot;
            packages = [
              tools.checkXilinxEnv
              tools.program-cli
              tools.deploy-hw
              tools.unload-driver
              tools.hot-reset
              tools.insert-driver
              tools.set-hugepages
              tools.gen-verible-filelist
              xdbPackage
            ];
            shellHook = compileCommandsHook;
          };
        }
        // lib.optionalAttrs isX86_64 {
          ultrascale = mkXilinxDevShell {
            board = doctor.boards.u280;
            fpgaPackage = "aurora-loopback-u280";
            fpgaArtifact = "cyt_top.bit";
            simPackageProject = packagePath "aurora-loopback-u280-sim" "project/sim/example_14_aurora_loopback.xpr";
            simPackageRuntime = packagePath "aurora-loopback-u280-sim" "project/sim";
            simSession = "aurora-ultrascale";
            simWorkspaceSuffix = "aurora-u280";
          };

          xilinx = mkXilinxDevShell {
            board = doctor.boards.u280;
            fpgaPackage = "aurora-loopback-u280";
            fpgaArtifact = "cyt_top.bit";
            simPackageProject = packagePath "aurora-loopback-u280-sim" "project/sim/example_14_aurora_loopback.xpr";
            simPackageRuntime = packagePath "aurora-loopback-u280-sim" "project/sim";
            simSession = "aurora-ultrascale";
            simWorkspaceSuffix = "aurora-u280";
          };
        };

        packages = {
          aurora-loopback-host = auroraHost;
          vivado = tools.vivado;
          hw_server = tools.hw_server;
          vitis_hls = tools.vitis_hls;
        }
        // auroraHwPackages
        // coyoteDriverPackages;

        apps = {
          program-cli = mkApp tools.program-cli "program-cli";
          deploy-hw = mkApp tools.deploy-hw "deploy-hw";
          unload-driver = mkApp tools.unload-driver "unload-driver";
          hot-reset = mkApp tools.hot-reset "hot-reset";
          insert-driver = mkApp tools.insert-driver "insert-driver";
          set-hugepages = mkApp tools.set-hugepages "set-hugepages";
          vivado = mkApp tools.vivado "vivado";
          hw_server = mkApp tools.hw_server "hw_server";
          vitis_hls = mkApp tools.vitis_hls "vitis_hls";
          aurora-loopback = mkApp auroraHost "aurora-loopback";
        };

        formatter = pkgs.nixfmt-rfc-style;
      }
    );

  nixConfig = {
    extra-sandbox-paths = "/share/xilinx";
  };
}
