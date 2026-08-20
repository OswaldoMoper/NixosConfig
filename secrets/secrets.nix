let
  omoper = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtc3UltPW/ccxhZzNcp/WhBQVr+1KY85XYdTKfKfa4M omoper@example.com";
  guest = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA guest@conect";
  spartanWSL = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILsDTaJJyizPTyf9S4DJUp+SqhIIKYjfGPBPnoEYdNLZ root@spartanWSL";
in
{
  "guest-password.age".publicKeys = [ omoper guest spartanWSL ];
}
