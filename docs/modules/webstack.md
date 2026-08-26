# webstack — Declarative Web Hosting Stack

This module centralizes web application deployment on NixOS. It supports pure Nginx hosting, Cloudflare Tunnel hosting or both, with automatic per-application systemd services

This module is only active when `webStack.enable = true`.

## Purpose

- Declarative hosting for Yesod and other web apps
- Eliminate redundant Nginx or cloudflared configurations across multiple hosts.
- Automatic systemd services per app
- Optional ACME certificates (Nginx apps only)
- Safe defaults (SSL, unique ports, unique names, unique domains)

## General Architecture

The module exposes two independent hosting stacks:

### 1. Nginx stack

```Nix
{
  webStack.nginx = {
    enable = true;
    apps = [
    # ... apps ...
    ];
  };
}
```

Features:

- Generate Nginx virtualHosts
- Enable ACME per domain
- Enforce HTTPS
- Create systemd services per app

#### VirtualHosts

For each app:

```Nix
{
  services.nginx.virtualHosts.<domain> = {
    enableACME = true;
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://localhost:<port>";
      proxyWebsockets = true;
    };
  };
}
```

### 2. Cloudflare Tunnel stack

```Nix
{
  webStack.tunnel = {
    enable = true;
    name = "main";
    credentials = "/etc/.cloudflared/uuid.json";
    apps = [
    # ... apps ...
    ];
    useNginx = true | false;
  };
}
```

Features:

- Create a Cloudflare tunnel
- Generate ingress rules per domain
- If `useNginx = true`, Cloudflare -> Nginx -> App
- If `useNginx = false`, Cloudflare -> App
- Don't use ACME (TLS via Cloudflare)
- Create systemd services per app

#### Ingress rules

If `useNginx = true`:

```Nix
{
  <domain> = "http://<domain>";
}
```

If `useNginx = false`:

```Nix
{
  <domain> = "http://localhost:<port>";
}
```

#### SSH Access

This module also allows to expose the SSH service of the host securely through tunnel:

```Nix
{
  webStack.tunnel.ssh = {
    enable = true;
    domain = "ssh.oswaldomoper.com";
    port = 22;
  };
}
```

- **Automatic ingress**: Creates a rule `ssh://localhost:22` on the tunnel.
- **Without ports exposure**: Don't require to allow port 22 on the extern firewall, the traffic travel inside the tunnel.
- **Dependent SSH**: if `tunnel.ssh.enable` is true, `tunnel.enable` must be true.
- **Obligatory Domain**: SSH can't be enable without `tunnel.ssh.domain`
- **Global unicity**: The domain and port of SSH are included on the assertions of duplicate of webStack.

## Options

### Top-level

| Option             | Type    | Default   | Description                                                      |
| ------------------ | ------- | --------- | ---------------------------------------------------------------- |
| `webStack.enable`  | boolean | `false`   | Enable the web hosting stack                                     |
| `webStack.manager` | string  | `"admin"` | System user that runs all app services                           |
| `webStack.email`   | string  | `""`      | Email for ACME certificates and notifications. Must not be empty |

### `webStack.nginx`

| Option         | Type        | Default | Description                            |
| -------------- | ----------- | ------- | -------------------------------------- |
| `nginx.enable` | boolean     | `false` | Enable the Nginx hosting stack         |
| `nginx.apps`   | list of App | `[]`    | Web apps to host via Nginx (with ACME) |

### `webStack.tunnel`

| Option               | Type        | Default  | Description                                                             |
| -------------------- | ----------- | -------- | ----------------------------------------------------------------------- |
| `tunnel.enable`      | boolean     | `false`  | Enable the Cloudflare Tunnel stack                                      |
| `tunnel.name`        | string      | `"main"` | Name of the Cloudflare tunnel                                           |
| `tunnel.credentials` | string      | -        | Path to credentials JSON file (default: `/etc/.cloudflared/uuid.json`)  |
| `tunnel.apps`        | list of App | `[]`     | Web apps to route through the tunnel                                    |
| `tunnel.useNginx`    | boolean     | `false`  | Route tunnel traffic through Nginx instead of directly to the app       |

### `webStack.tunnel.ssh`

| Option              | Type    | Default | Description                                         |
| ------------------- | ------- | ------- | --------------------------------------------------- |
| `tunnel.ssh.enable` | boolean | `false` | Expose the host SSH service through the tunnel      |
| `tunnel.ssh.domain` | string  | `""`    | Public domain for SSH access. Required when enabled |
| `tunnel.ssh.port`   | port    | `22`    | Internal port the SSH service listens on            |

## App Schema

Each app in `nginx.apps` or `tunnel.apps` has:

```Nix
{
  # "managed" (default) or "profile" — see below
  kind = "managed";
  name = "myapp";
  domain = "myapp.example.com";
  port = 3000;
  # Derivation OR flake input. Required for "managed", unused for "profile"
  package = inputs.myapp;
  # Optional binary override
  binaryName = "myapp-custom";
  # Non-secret environment variables
  environment = { ... };
  # Secrets: a file of KEY=value lines on the target host
  environmentFile = "/run/agenix/myapp-env";
  # Packages added to PATH (bin + sbin)
  path = [ pkgs.git pkgs.curl ];
  # Optional working directory
  workDir = "/var/lib/myapp";
  # Extra command-line arguments
  extraArgs = [ "--verbose" ];
}
```

### `kind`: two shapes of app

| | `"managed"` (default) | `"profile"` |
| --- | --- | --- |
| Systemd unit | webStack generates it | the app's own module |
| nginx virtualHost | webStack generates it | the app's own module |
| Cloudflare tunnel ingress | webStack | **webStack** |
| Firewall, ACME email | webStack | **webStack** |
| Uniqueness assertions | webStack | **webStack** |
| `package` | required | unused |

Use `"managed"` for a single-binary app: give it a package and some environment and
webStack does the rest. Use `"profile"` for an app that ships its own NixOS module
with a `services.<app>.profile` interface — it owns its unit, its vhost, its secrets
and its database wiring, and webStack contributes only the edge it does not own.

The point of listing a `"profile"` app here at all is the last three rows: without an
entry, a port or domain collision between it and anything else on the host goes
unnoticed until deployment. With one, it fails during evaluation.

```Nix
{
  webStack.nginx.apps = [
    { name = "blog"; domain = "example.com"; port = 2001; package = inputs.blog; }
    { kind = "profile"; name = "example2"; domain = "example2.org"; port = 3003; }
  ];
  services.example2.profile = {
    enable = true;
    mode = "production";
    serverName = "example2.org";
    ports.backend = 3003;
  };
}
```

### Secrets

`environment` is rendered into the systemd unit, which lives world-readable in the nix
store. Anything secret belongs in `environmentFile`, a path on the target host that
systemd reads at start time and that never enters the store:

```Nix
{
  environment = { MYAPP_PGUSER = "myapp"; MYAPP_PGDATABASE = "myapp"; };
  environmentFile = "/run/agenix/myapp-env";   # contains MYAPP_PGPASS=…
}
```

### Package Resolution

The module accepts:

- A derivation
- A flake input with .packages.${system}.${name}-wrapper
- Or .packages.${system}.${name}

The wrapper is resolved automatically.

## Systemd Services

Each **`managed`** app (of nginx or tunnel) generates a service. `profile` apps do not:
their own module owns the unit.

- Name: `app.name`
- User: `webStack.manager`
- Variables: `app.environment`
- Secrets file: `app.environmentFile`, if set
- Extended PATH: `app.path`
- Working directory: `app.workDir`, if set
- Binary:
  - If `binaryName = ""` -> `${name}-wrapped`
  - If defined -> use this name

```Nix
{
  ExecStart = "${pkg}/bin/${bin} ${escapeShellArgs app.extraArgs}";
  Restart = "always";
  # only when the corresponding option is set
  WorkingDirectory = app.workDir;
  EnvironmentFile = app.environmentFile;
}
```

## Validations

The module enforces:

- The `email` must not be empty
- Every app with `kind = "managed"` must have a `package`
- `nginx.apps` or `tunnel.apps` must not be empty when `nginx` or `tunnel` enabled respectively
- All app ports must be unique
- All app domains must be unique
- All app names must be unique
- If tunnel is enabled -> must be apps on `tunnels.apps`
- If nginx is enabled -> must be apps on `nginx.apps`

These are implemented via Nix assertions.

## Examples

### Cloudflare Tunnel + Nginx Proxy

```nix
{  
  webStack = {
    enable = true;
    email = "admin@example.com";
    manager = "omoper";

    nginx.enable = true;

    tunnel = {
      enable = true;
      name = "main";
      credentials = "/home/omoper/.cloudflared/uuid.json";
      useNginx = true;
      apps = [
        {
          name = "nixTalk";
          domain = "nixtalk.oswaldomoper.com";
          port = 2000;
          package = inputs.nixTalk;
          environment = {
            nixTalk_STATIC = "/home/omoper/nixTalk/static";
            nixTalk_PORT = "2000";
            nixTalk_APPROOT = "https://nixtalk.oswaldomoper.com";
          };
        }
      ];
    };
  };
}
```

### Cloudflare Tunnel

```Nix
{pkgs, ...}: {
  # ... other host configurations ...
  webStack = {
    enable = true;
    email = "admin@example.com";
    manager = "omoper";
    tunnel = {
      credentials = "/home/omoper/.cloudflared/uuid.json";
      name = "main";
      enable = true;
      apps = [
        {
          name = "nixTalk";
          domain = "nixTalk.oswaldomoper.com";
          port = 2000;
          environment = {
            # ... other environment variables ...
            nixTalk_STATIC     = "/home/omoper/nixTalk/static";
            nixTalk_PORT       = "2000";
            nixTalk_UPLOAD     = "/home/omoper/upload";
            nixTalk_APPROOT    = "https://nixTalk.oswaldomoper.com";
            # if your app uses postgres
            nixTalk_PGUSER     = "omoper";
            # Secrets go in environmentFile, never here — `environment` lands in the nix store.
            nixTalk_PGHOST     = "localhost"; # or your dbhost
            nixTalk_PGPORT     = "5432"; # or the port you use
            nixTalk_PGDATABASE = "nixTalk";
            nixTalk_PGPOOLSIZE = "10";
            # ... other environment variables ...
          };
          package = inputs.nixTalk;
        }
      ];
    }
  };
  # ... other host configurations ...
}
```

### Nginx

```Nix
{pkgs, ...}: {
  # ... other host configurations ...
  webStack = {
    enable = true;
    email = "admin@example.com";
    manager = "admin";
    nginx = {
      enable = true;
      apps = [
        {
          name = "myapp";
          domain = "myapp.example.com";
          port = 3000;
          environment = {
            # ... other environment variables ...
            example_STATIC     = "/home/admin/example/static";
            example_UPLOAD     = "/home/admin/upload";
            example_PORT       = "3000";
            example_APPROOT    = "https://myapp.example.com";
            # if your app uses postgres
            example_PGUSER     = "your postgres user";
            # Secrets go in environmentFile, never here — `environment` lands in the nix store.
            example_PGHOST     = "localhost"; # or your dbhost
            example_PGPORT     = "5432"; # or the port you use
            example_PGDATABASE = "your database name";
            example_PGPOOLSIZE = "10";
            # ... other environment variables ...
          };
          package = inputs.myapp;
        }
      ];
    };
  };
  # ... other host configurations ...
}
```

## When to use this module

Use it when:

- You want declarative hosting
- You want automatic systemd services
- You want ACME or Cloudflare Tunnel integration
- You want to avoid repeating configurations across hosts

Do **not** use it for:

- Static-only hosting
- Reverse proxies unrelated to apps
- Docker-based deployments
