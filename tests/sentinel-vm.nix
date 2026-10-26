{ pkgs, module }:

let
  keys = import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs;
in
pkgs.testers.runNixOSTest {
  name = "sentinel";
  nodes.box = { lib, pkgs, ... }: {
    imports = [ module ];
    services.openssh.enable = true;
    users.users.root.openssh.authorizedKeys.keys = [ keys.snakeOilPublicKey ];
    alerts.recipientsFile = "/dev/null";
    sentinel.enable = true;
    systemd.services.sentinel.environment.SENTINEL_MAIL =
      lib.mkForce "${pkgs.writeShellScript "fake-mail" "cat > /tmp/mail"}";
    environment.systemPackages = [ pkgs.openssh ];
  };
  testScript = ''
    box.wait_for_unit("sshd.service")
    box.succeed("install -m600 ${keys.snakeOilPrivateKey} /root/key")
    ssh = "ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes"
    box.succeed(f"{ssh} -i /root/key root@127.0.0.1 true")

    with subtest("the first pass mails the login and learns it"):
        box.succeed("systemctl start sentinel.service")
        print(box.succeed("cat /tmp/mail"))
        box.succeed("grep -F 'new ssh key: root SHA256:' /tmp/mail")
        box.succeed("grep -F 'new ssh network: root 127.0.0.0/16' /tmp/mail")

    with subtest("a second pass with nothing new mails nothing"):
        box.succeed("rm /tmp/mail")
        box.succeed(f"{ssh} -i /root/key root@127.0.0.1 true")
        box.succeed("systemctl start sentinel.service")
        box.fail("test -e /tmp/mail")

    with subtest("a key taken from ~/.ssh/authorized_keys mails"):
        box.succeed("ssh-keygen -q -t ed25519 -N ''' -f /root/other")
        box.succeed("mkdir -p /root/.ssh && cat /root/other.pub >> /root/.ssh/authorized_keys")
        box.succeed(f"{ssh} -i /root/other root@127.0.0.1 true")
        box.succeed("systemctl start sentinel.service")
        print(box.succeed("cat /tmp/mail"))
        box.succeed("grep -F 'ssh key accepted from outside /etc/ssh/authorized_keys.d: /root/.ssh/authorized_keys' /tmp/mail")

    with subtest("an executable left in /tmp mails"):
        box.succeed("rm /tmp/mail && cp ${pkgs.hello}/bin/hello /tmp/x && chmod +x /tmp/x")
        box.succeed("systemctl start sentinel.service")
        box.succeed("grep -F 'new executable in a temporary directory: /tmp/x' /tmp/mail")
  '';
}
