rec {
  # A managed app is its own unit; a profile app is named by the module that
  # ships it, and the two need not match, so nothing here can derive it.
  unitOf = a: if a.unit != null then a.unit else (if a.kind == "managed" then a.name else null);

  # The units of a host's webStack apps; empty when the host has no webStack.
  appUnitsOf =
    cfg:
    builtins.filter (u: u != null) (
      map unitOf (if cfg ? webStack then cfg.webStack.tunnel.apps ++ cfg.webStack.nginx.apps else [ ])
    );
}
