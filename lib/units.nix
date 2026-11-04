{
  # A managed app is its own unit; a profile app is named by the module that
  # ships it, and the two need not match, so nothing here can derive it.
  unitOf = a: if a.unit != null then a.unit else (if a.kind == "managed" then a.name else null);
}
