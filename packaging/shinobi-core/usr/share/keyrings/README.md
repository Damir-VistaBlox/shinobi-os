# The archive signing key, and where its other half is

`shinobi-core` ships `usr/share/keyrings/shinobi-archive-keyring.gpg` — the
**public** half of the key that signs the Shinobi overlay archive. This file is
the only record of how that key is managed, because nothing else in the tree
carries the information and a key nobody can reconstruct is a release nobody can
ship.

## Why the public key ships in the package

`shinobi repo enable` writes a `sources.list` entry with `signed-by=` pointing at
a keyring in `/usr/share/keyrings`. Until this key existed, that path was a path
to nothing: `shinobi repo enable` failed on every system it was ever run on,
including the live image, and `shinobi repo status` reported the keyring as
missing. The command looked complete and had never been exercised.

Shipping the keyring means an installed system can authenticate the archive
without fetching anything first. That ordering is the point — a key retrieved
over the channel it authenticates proves nothing about the packages that channel
serves.

## The private key

The secret half is **not** in this repository and must never be. It belongs
where release signing belongs:

- an offline secret store or CI secret (with the release key's passphrase held
  separately, so neither one is enough on its own), and
- nothing else. No developer machine, no image, no chat log.

Current key, for identifying it rather than for using it:

```
fingerprint  DA58F26CA5AA545CCD149FFE7CB3AD229C20E203
uid          Shinobi OS Archive Signing Key <archive@shinobi-os.local>
algorithm    ed25519 [sign only]
```

### Verifying the committed keyring matches this fingerprint

```sh
gpg --show-keys --with-colons \
  packaging/shinobi-core/usr/share/keyrings/shinobi-archive-keyring.gpg \
  | awk -F: '/^fpr/{print $10}'
```

### Signing a repository with it

```sh
packaging/build-repo.py core/*.deb desktop/*.deb --key "$SIGNING_KEY"
```

`build-repo.py` refuses to publish unsigned unless it is told explicitly to, and
says so on stderr when it is, because an unsigned archive added to a
`sources.list` looks exactly like a signed one until apt prompts.

## Rotating the key

1. Generate the new keypair **offline**, in a scratch `GNUPGHOME`.
2. Export the public half and replace
   `packaging/shinobi-core/usr/share/keyrings/shinobi-archive-keyring.gpg`,
   exporting *both* keys during the overlap window.
3. Update the fingerprint above.
4. Sign the new archive with the new key.
5. Only after a release has been signed by the new key: drop the old one and
   re-export.

An installed system only ever learns about a new key by receiving the package
that carries it, so rotation means an update rather than an out-of-band fetch —
which is the behaviour you want, and the reason the key lives here instead of
in a URL.