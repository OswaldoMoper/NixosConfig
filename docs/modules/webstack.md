# webstack — Web Hosting Stack

This module provides a unified interface for hosting web applications on NixOS. It supports both pure nginx hosting and nginx + Cloudflare Tunnel hosting, with automatic ACME certificates and per-application systemd services.

## Purpose

- Provide a declarative hosting stack for Yesod and other web apps
- Avoid duplicating nginx or cloudflared configuration across hosts
- Automatically generate systemd services per app
- Support both public nginx hosting and Cloudflare Tunnel hosting
- Ensure safe defaults (ACME, SSL, unique ports)

This module activates only when `webStack.enable = true`.

## Modes

### `"nginx"`

- nginx is enabled (always)
- ACME certificates are enabled
- HTTPS is enforced
- Each app gets a virtualHost with SSL
- Cloudflare Tunnel is **not** enabled

Use this mode for public-facing servers with direct internet access.

### `"tunnel"`

- nginx is still enabled (reverse proxy)
- ACME is disabled (Cloudflare handles TLS)
- Cloudflare Tunnel is enabled
- Each app gets an ingress rule
- HTTPS termination happens at Cloudflare

Use this mode for:

- WSL hosts
- Development machines
- Servers behind NAT
- Zero-trust deployments

## Options

### `webStack.enable`

Enables the hosting stack.

### `webStack.mode`

Hosting mode:

```nix
"nginx" | "tunnel"
```

Defaults to `"tunnel"`.

### `webStack.email`

Email used for ACME certificates and notifications. Required.

### `webStack.manager`

System user that runs the web applications. Defaults to `"admin"`.

### `webStack.tunnelName`

Name of the Cloudflare Tunnel. Defaults to `"main"`.

### `webStack.tunnelCredentials`

Path to the Cloudflare Tunnel credentials file. Defaults to:

```code
/etc/.cloudflared/uuid.json
```

### `webStack.apps`

List of applications to host. Each app has:

```nix
{
  name = "myapp";
  domain = "myapp.example.com";
  port = 3000;
  static = "/path/to/static";
  package = inputs.myapp.packages.${pkgs.system}.myapp-wrapper;
}
```

## Validations

The module enforces:

- `email` must not be empty
- `apps` must not be empty
- all app ports must be unique

These are implemented via Nix assertions.

## nginx Hosting (always enabled)

nginx is always enabled when `webStack.enable = true`. Each app gets a virtualHost:

```nix
services.nginx.virtualHosts.<domain> = {
  enableACME = (cfg.mode == "nginx");
  forceSSL = (cfg.mode == "nginx");
  locations."/" = {
    proxyPass = "http://localhost:<port>";
    proxyWebsockets = true;
  };
};
```

When `mode = "nginx"`:

- ACME is enabled
- HTTPS is enforced

When `mode = "tunnel"`:

- ACME is disabled
`HTTPS is not forced (Cloudflare handles TLS)

## Clodflare Tunnel Hosting

When  `mode = "tunnel"`:

- nginx is still enabled (reverse proxy)
- ACME is disabled
- Cloudflare Tunnel is enabled

```Nix
services.cloudflared.tunnels.<tunnelName> = {
  credentialsFile = cfg.tunnelCredentials;
  ingress = {
    <domain> = "http://localhost:<port>";
  };
  default = "http_status:404";
};
```

TLS termination happens at Cloudflare.

## Systemd Services

Each app generates a systemd service:

- Name: `app.name`
- User: `webStack.manager`
- Environment variables:
  - `YESOD_STATIC_DIR`
  - `YESOD_PORT`
  - `YESOD_APPROOT`
- ExecStart:

```Nix
${app.package}/bin/${app.name}-wrapped --verbose
```

- Restart policy: `always`

Example:

```bash
systemctl status nixTalk
```

## Examples

### Cloudflare Tunnel Hosting

```Nix
{pkgs, ...}: {
  # ... other host configurations ...
  webStack = {
    enable = true;
    mode = "tunnel";
    email = "admin@example.com";
    manager = "omoper";
    tunnelCredentials = "/home/omoper/.cloudflared/uuid.json";

    apps = [
      {
        name = "nixTalk";
        domain = "nixTalk.oswaldomoper.com";
        port = 2000;
        static = "/home/omoper/nixTalk/static";
        package = inputs.nixTalk.packages.${pkgs.system}.nixTalk-wrapper;
      }
    ];
  };
  # ... other host configurations ...
}
```

### nginx hosting

```Nix
{pkgs, ...}: {
  # ... other host configurations ...
  webStack = {
    enable = true;
    mode = "nginx";
    email = "admin@example.com";
    manager = "admin";

    apps = [
      {
        name = "myapp";
        domain = "myapp.example.com";
        port = 3000;
        static = "/home/admin/myapp/static";
        package = inputs.myapp.packages.${pkgs.system}.myapp-wrapper;
      }
    ];
  };
  # ... other host configurations ...
}
```

## When to use this module

Use it when:

- A host needs to run web applications
- You want declarative hosting
- You want automatic systemd services
- You want ACME or Cloudflare Tunnel integration

Do **not** use it for:

- Static-only hosting
- Reverse proxies unrelated to apps
- Docker-based deployments
