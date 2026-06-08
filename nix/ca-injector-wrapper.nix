# ─── nix/ca-injector-wrapper.nix ───────────────────────────────────────
# The runc shim docker calls instead of runc, to transparently inject MITM
# trust into UNMODIFIED containers (design §13.5). Extracted here so both
# consumers share ONE definition:
#   - NixOS:  modules/ca-injector.nix  (virtualisation.docker default-runtime)
#   - Ubuntu: ubuntu-client.nix        (/etc/docker/daemon.json runtimes)
#
# It is fully node-agnostic: every path it references is fixed
# (/etc/cache-mitm-ca-bundle.crt, /etc/cache-mitm-hosts), so the per-node
# /etc/hosts content (FQDN → that node's LAN IP) is supplied separately by
# each consumer. Strictly FAIL-OPEN: only the `create` subcommand is touched,
# any error leaves config.json untouched and still exec's real runc.
{ pkgs, lib }:
let
  # Combined bundle (public CAs ++ MITM CA), assembled at activation. Bind-
  # mounted at this same fixed path inside the container and pointed at by the
  # SSL_CERT_* env vars below.
  caBundle = "/etc/cache-mitm-ca-bundle.crt";

  # Belt-and-suspenders bind-mount destinations across distros, plus the fixed
  # path the env vars reference. runc creates any missing mountpoint, so
  # listing a path the image lacks is harmless.
  caDests = [
    caBundle                                # fixed path the env vars point at
    "/etc/ssl/certs/ca-certificates.crt"   # debian/ubuntu/alpine
    "/etc/ssl/cert.pem"                     # alpine/openssl, busybox wget
    "/etc/pki/tls/certs/ca-bundle.crt"      # rhel/fedora/centos
  ];

  # Env vars steering each common TLS library at our bundle. Appended LAST to
  # .process.env so they override any value the image set.
  caEnv = [
    "SSL_CERT_FILE=${caBundle}"          # openssl, curl, go, ruby
    "CURL_CA_BUNDLE=${caBundle}"         # curl (even the /cacert.pem build)
    "REQUESTS_CA_BUNDLE=${caBundle}"     # python-requests
    "GIT_SSL_CAINFO=${caBundle}"         # git over https
    "NODE_EXTRA_CA_CERTS=${caBundle}"    # node (merged with its built-ins)
  ];

  # jq program (store path baked at build) that appends our bind mounts to
  # .mounts (LAST, so /etc/hosts wins over docker's own mount) and our env
  # vars to .process.env (LAST, so they override the image's values).
  patchJq = ''
    .mounts = ((.mounts // []) + [
      { "destination": "/etc/hosts", "type": "bind",
        "source": "/etc/cache-mitm-hosts", "options": ["rbind","ro"] }
  '' + lib.concatMapStringsSep "\n" (d: '',
      { "destination": "${d}", "type": "bind",
        "source": "${caBundle}", "options": ["rbind","ro"] }'') caDests + ''
    ])
    | .process.env = ((.process.env // []) + ${builtins.toJSON caEnv})
  '';
in
pkgs.writeShellApplication {
  name = "runc-with-ca-wrapper";
  runtimeInputs = with pkgs; [ jq coreutils runc ];
  text = ''
    # Locate the create subcommand and its --bundle. runc's global flags
    # precede the subcommand, so scan every arg. Bundle defaults to "."
    # (the containerd shim cd's into the bundle before calling runc).
    bundle="."
    is_create=0
    prev=""
    for a in "$@"; do
      case "$a" in
        create)     is_create=1 ;;
        --bundle=*) bundle="''${a#--bundle=}" ;;
      esac
      case "$prev" in
        --bundle|-b) bundle="$a" ;;
      esac
      prev="$a"
    done

    if [ "$is_create" -eq 1 ] && [ -f "$bundle/config.json" ]; then
      cfg="$bundle/config.json"
      tmp="$(mktemp)" || tmp=""
      if [ -n "$tmp" ] && jq ${lib.escapeShellArg patchJq} "$cfg" > "$tmp" 2>/dev/null \
         && [ -s "$tmp" ]; then
        cat "$tmp" > "$cfg" 2>/dev/null || true
      fi
      [ -n "$tmp" ] && rm -f "$tmp" 2>/dev/null || true
    fi

    exec ${pkgs.runc}/bin/runc "$@"
  '';
}
