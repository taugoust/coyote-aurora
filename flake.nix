{
  description = "Coyote Aurora bridge for QShell peer-path validation";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
    coyote = {
      # Match the deployed Rose image's Aurora framing, 512-bit CDC, and
      # Immediate NFC configuration exactly.
      url = "github:taugoust/Coyote/6b9b0ae2b2928d9d0c9afce4313fcec3f128b705";
      flake = false;
    };
    coyote-nix = {
      url = "github:TUM-DSE/coyote-nix/master";
      inputs.coyote.follows = "coyote";
      inputs.flake-utils.follows = "flake-utils";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    qshell = {
      url = "git+ssh://git@github.com/TUM-DSE/QShell.git?ref=master&rev=e9cfaabae0abfc779bcd3ca4c8974778f73720df";
      flake = false;
    };
    deployment-coyote = {
      url = "git+ssh://git@github.com/taugoust/Coyote.git?ref=linux-7-driver-compat&rev=0e4e5ae66f42f53436d9b31f56d0704ccab9dbfb";
      flake = false;
    };
    deployment-coyote-nix = {
      url = "git+ssh://git@github.com/TUM-DSE/coyote-nix.git?ref=multifunction-endpoint-reset&rev=61e60fd8517c52dfcbcba1a01d34b73101eeb234";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    doctor-cluster-xilinx = {
      url = "git+ssh://git@github.com/TUM-DSE/doctor-cluster-xilinx.git?rev=ce34aac85ebed773484dc62d5fe1531ac45150d2";
      inputs.doctor-cluster-config.url = "git+ssh://git@github.com/TUM-DSE/doctor-cluster-config.git?rev=1ba4cd371f4f20ef0824775e104da288514397e5";
    };
    rose-helios = {
      url = "git+ssh://git@github.com/TUM-DSE/helios-coyote.git?ref=qshell-migration&rev=a8909a44e408490f5f8d7dffdc5176edf590a06d";
      flake = false;
    };
    xdb.url = "github:taugoust/xdb";
  };

  outputs =
    inputs@{
      nixpkgs,
      flake-utils,
      coyote,
      qshell,
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
        qshellRoot = qshell;
        deploymentCoyoteRoot = inputs.deployment-coyote;
        deploymentCoyoteNix = inputs.deployment-coyote-nix;
        doctor = doctorClusterXilinx.lib.mkXilinxContext { inherit pkgs system; };
        driverPkgs =
          doctorClusterXilinx.inputs.doctor-cluster-config.inputs.nixpkgs.legacyPackages.${system};
        xilinxShareRoot = doctor.xilinxShareRoot;
        driverKernels = doctor.driverKernels;

        tools = coyoteNix.lib.mkTools {
          inherit pkgs coyoteRoot xilinxShareRoot;
          platforms = linuxSystems;
        };
        deploymentTools = deploymentCoyoteNix.lib.mkTools {
          inherit pkgs xilinxShareRoot;
          coyoteRoot = deploymentCoyoteRoot;
          platforms = linuxSystems;
        };
        mkApp = deploymentCoyoteNix.lib.mkApp;

        hwSource = lib.fileset.toSource {
          root = ./hw;
          fileset = lib.fileset.unions [
            ./hw/CMakeLists.txt
            ./hw/src
          ];
        };

        csrRegressionSource = lib.fileset.toSource {
          root = ./hw;
          fileset = lib.fileset.unions [
            ./hw/src/hdl/aurora_loopback_csrs.sv
            ./hw/tb/aurora_loopback_csrs_tb.sv
          ];
        };

        bridgeRegressionSource = lib.fileset.toSource {
          root = ./hw;
          fileset = lib.fileset.unions [
            ./hw/src/hdl/axis_stream_fifo_2.sv
            ./hw/src/hdl/aurora_host_peer_bridge.sv
            ./hw/tb/axis_stream_fifo_2_tb.sv
            ./hw/tb/aurora_host_peer_bridge_tb.sv
          ];
        };

        auroraCsrRegression =
          pkgs.runCommand "aurora-loopback-csr-regression"
            {
              nativeBuildInputs = with pkgs; [
                gnumake
                python3
                stdenv.cc
                verilator
              ];
            }
            ''
              cp -R ${csrRegressionSource} source
              chmod -R u+w source

              verilator \
                --binary \
                --timing \
                --assert \
                -Wall \
                --top-module aurora_loopback_csrs_tb \
                --Mdir obj_dir \
                source/src/hdl/aurora_loopback_csrs.sv \
                source/tb/aurora_loopback_csrs_tb.sv

              ./obj_dir/Vaurora_loopback_csrs_tb | tee regression.log
              grep -F \
                "PASS: Aurora AXI-Lite CSR writes honor WSTRB and preserve adjacent registers" \
                regression.log

              mkdir -p "$out"
              printf '%s\n' \
                "PASS: Aurora AXI-Lite CSR writes honor WSTRB and preserve adjacent registers" \
                > "$out/result.txt"
            '';

        auroraBridgeRegression =
          pkgs.runCommand "aurora-peer-bridge-stream-regression"
            {
              nativeBuildInputs = with pkgs; [
                gnumake
                python3
                stdenv.cc
                verilator
              ];
            }
            ''
              cp -R ${bridgeRegressionSource} source
              chmod -R u+w source

              verilator \
                --binary \
                --timing \
                --assert \
                -Wall \
                -Wno-fatal \
                --top-module axis_stream_fifo_2_tb \
                --Mdir obj_dir \
                source/src/hdl/axis_stream_fifo_2.sv \
                source/tb/axis_stream_fifo_2_tb.sv

              ./obj_dir/Vaxis_stream_fifo_2_tb | tee regression.log
              grep -F \
                "PASS: registered two-entry stream queue preserves records, stalls, throughput, and flush" \
                regression.log

              verilator \
                --binary \
                --timing \
                --assert \
                -Wall \
                -Wno-fatal \
                --top-module aurora_host_peer_bridge_tb \
                --Mdir bridge_obj_dir \
                source/src/hdl/axis_stream_fifo_2.sv \
                source/src/hdl/aurora_host_peer_bridge.sv \
                source/tb/aurora_host_peer_bridge_tb.sv

              ./bridge_obj_dir/Vaurora_host_peer_bridge_tb | tee -a regression.log
              grep -F \
                "PASS: Aurora host/peer bridge preserves both directions, backpressure, and link epochs" \
                regression.log

              mkdir -p "$out"
              cp regression.log "$out/"
            '';

        roseProtocolContract = pkgs.runCommand "aurora-rose-qsh2-protocol-contract" { } ''
          diff -u ${inputs.rose-helios}/sw/include/helios/helios_protocol.h \
            ${./sw/include/helios/helios_protocol.h}
          diff -u ${inputs.rose-helios}/sw/src/helios_protocol.cpp \
            ${./sw/src/helios_protocol.cpp}
          grep -F '#include <qshell/qshell_abi_generated.hpp>' \
            ${./sw/include/aurora/qsh2_record.h} >/dev/null
          grep -F '::qshell::abi::schema_helios_phenom_syndrome' \
            ${./sw/include/helios/helios_qshell_protocol.h} >/dev/null
          if grep -RE \
            'COYOTE_HOST_STREAM_BEAT_BYTES|record_abi_version[[:space:]]*=[[:space:]]*2|record_header_bytes[[:space:]]*=[[:space:]]*48|schema_(opaque_loopback|helios_[a-z_]+)[[:space:]]*=[[:space:]]*0x' \
            ${./sw/include} ${./sw/src}; then
            echo 'Aurora host source contains a hand-written QSH2 ABI definition' >&2
            exit 1
          fi
          touch "$out"
        '';

        auroraPeerHost = pkgs.stdenv.mkDerivation {
          pname = "aurora-qshell-peer-host";
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
          QSHELL_ROOT = qshellRoot;
          cmakeFlags = [
            "-DCMAKE_POLICY_VERSION_MINIMUM=3.10"
            "-DCMAKE_POLICY_DEFAULT_CMP0167=OLD"
            "-DQSHELL_ROOT=${qshellRoot}"
          ]
          ++ lib.optionals (!isX86_64) [ "-DEN_AVX=0" ];

          installPhase = ''
            runHook preInstall

            mkdir -p $out/bin $out/lib $out/libexec
            for program in aurora-qshell-peer aurora-qshell-loopback; do
              install -m755 "$program" "$out/libexec/$program"

              cat > "$out/bin/$program" <<EOF
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
            exec "$out/libexec/$program" "\$@"
            EOF
              chmod +x "$out/bin/$program"
            done

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
            for program in aurora-qshell-peer aurora-qshell-loopback; do
              patchelf --set-rpath "$lib_path" "$out/libexec/$program"
            done

            for so in $out/lib/*.so*; do
              [ -e "$so" ] || continue
              if [ -f "$so" ]; then
                patchelf --set-rpath "$lib_path" "$so" || true
              fi
            done

            runHook postInstall
          '';

          doCheck = true;
          checkPhase = ''
            runHook preCheck
            ctest --output-on-failure
            runHook postCheck
          '';

          meta = {
            description = "QSH2 syndrome/correction runner for the Coyote Aurora peer bridge";
            mainProgram = "aurora-qshell-peer";
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
            pnamePrefix = "aurora-qshell-peer-bridge";
            projectName = "qshell_peer_bridge";
            boards = {
              u280 = {
                inherit (doctor.boards.u280) xilinxVersion simXilinxVersion;
                # The Aurora QSFP1 backend intentionally skips optional
                # post-opt/place/phys-opt checkpoints to avoid Vivado 2023.2
                # checkpoint/timing-archive crashes. Only final routed/static
                # checkpoints are required artifacts.
                skipIntermediateRouteCheckpoints = true;
              };
            };
          }
        );

        coyoteDriverPackages = lib.optionalAttrs isX86_64 (
          deploymentCoyoteNix.lib.mkCoyoteDriverPackages {
            pkgs = driverPkgs;
            inherit driverKernels;
            coyoteRoot = deploymentCoyoteRoot;
            inherit (doctor) targetPlatforms;
          }
        );

        packagePath = packageName: path: "${auroraHwPackages.${packageName}}/${path}";

        claraDeploymentTools = pkgs.symlinkJoin {
          name = "aurora-qshell-peer-clara-deployment-tools";
          paths = [
            deploymentTools.hot-reset
            deploymentTools.insert-driver
            deploymentTools.program-cli
            deploymentTools.set-hugepages
            deploymentTools.unload-driver
          ];
        };

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
          export QSHELL_ROOT=${qshellRoot}

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
            simProjectName ? "qshell_peer_bridge.xpr",
          }:
          deploymentCoyoteNix.lib.mkCoyoteDevShell {
            inherit pkgs board;
            tools = deploymentTools;
            coyoteRoot = deploymentCoyoteRoot;
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
          default = deploymentCoyoteNix.lib.mkCoyoteDevShell {
            inherit pkgs;
            tools = deploymentTools;
            coyoteRoot = deploymentCoyoteRoot;
            packages = [
              deploymentTools.checkXilinxEnv
              deploymentTools.program-cli
              deploymentTools.deploy-hw
              deploymentTools.unload-driver
              deploymentTools.hot-reset
              deploymentTools.insert-driver
              deploymentTools.set-hugepages
              deploymentTools.gen-verible-filelist
              xdbPackage
            ];
            shellHook = compileCommandsHook;
          };
        }
        // lib.optionalAttrs isX86_64 {
          ultrascale = mkXilinxDevShell {
            board = doctor.boards.u280;
            fpgaPackage = "aurora-qshell-peer-bridge-u280";
            fpgaArtifact = "cyt_top.bit";
            simPackageProject = packagePath "aurora-qshell-peer-bridge-u280-sim" "project/sim/qshell_peer_bridge.xpr";
            simPackageRuntime = packagePath "aurora-qshell-peer-bridge-u280-sim" "project/sim";
            simSession = "aurora-ultrascale";
            simWorkspaceSuffix = "aurora-u280";
          };

          xilinx = mkXilinxDevShell {
            board = doctor.boards.u280;
            fpgaPackage = "aurora-qshell-peer-bridge-u280";
            fpgaArtifact = "cyt_top.bit";
            simPackageProject = packagePath "aurora-qshell-peer-bridge-u280-sim" "project/sim/qshell_peer_bridge.xpr";
            simPackageRuntime = packagePath "aurora-qshell-peer-bridge-u280-sim" "project/sim";
            simSession = "aurora-ultrascale";
            simWorkspaceSuffix = "aurora-u280";
          };
        };

        checks = {
          aurora-loopback-csr-regression = auroraCsrRegression;
          aurora-peer-bridge-stream-regression = auroraBridgeRegression;
          aurora-rose-qsh2-protocol-contract = roseProtocolContract;
        };

        packages = {
          aurora-qshell-peer-host = auroraPeerHost;
          aurora-qshell-peer-clara-deployment-tools = claraDeploymentTools;
          vivado = tools.vivado;
          hw_server = tools.hw_server;
          vitis_hls = tools.vitis_hls;
        }
        // auroraHwPackages
        // coyoteDriverPackages;

        apps = {
          program-cli = mkApp deploymentTools.program-cli "program-cli";
          deploy-hw = mkApp deploymentTools.deploy-hw "deploy-hw";
          unload-driver = mkApp deploymentTools.unload-driver "unload-driver";
          hot-reset = mkApp deploymentTools.hot-reset "hot-reset";
          insert-driver = mkApp deploymentTools.insert-driver "insert-driver";
          set-hugepages = mkApp deploymentTools.set-hugepages "set-hugepages";
          vivado = mkApp tools.vivado "vivado";
          hw_server = mkApp tools.hw_server "hw_server";
          vitis_hls = mkApp tools.vitis_hls "vitis_hls";
          aurora-qshell-peer = mkApp auroraPeerHost "aurora-qshell-peer";
          aurora-qshell-loopback = mkApp auroraPeerHost "aurora-qshell-loopback";
        };

        formatter = pkgs.nixfmt-rfc-style;
      }
    );

  nixConfig = {
    extra-sandbox-paths = "/share/xilinx";
  };
}
