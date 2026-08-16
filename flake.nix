{
  description = "Dev shell for the columbus GPU (OpenGL/EGL) Wayland example";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        # libglvnd provides the EGL / GLESv2 client dispatch libraries
        # (libEGL.so.1, libGLESv2.so.2). mesa provides the actual driver and
        # the DRI/EGL-vendor files used by the offscreen EGL context.
        # libgbm (mesa-libgbm) is needed to allocate GPU dma-bufs that are
        # then imported into EGL and presented to Wayland via zwp_linux_dmabuf_v1.
        libglvnd = pkgs.libglvnd;
        mesa = pkgs.mesa;
        gbm = pkgs.libgbm;
      in {
        devShells.default = pkgs.mkShell {
          name = "columbus-gpu";
          buildInputs = [ libglvnd mesa gbm ];
          shellHook = ''
            export LD_LIBRARY_PATH="${libglvnd}/lib:${mesa}/lib:${gbm}/lib:$LD_LIBRARY_PATH"
            export LIBGL_DRIVERS_PATH="${mesa}/lib/dri"
            export __EGL_VENDOR_LIBRARY_PATHS="${mesa}/share/glvnd/egl_vendor.d"
          '';
        };
      });
}
