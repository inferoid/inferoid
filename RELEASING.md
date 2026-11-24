# Releasing

Two long-lived branches:

- `staging`: every feature PR targets it. CI must be green before merging.
- `main`: what users get. Only `staging` is merged into it, after it has been tested on a real Mac.

## Test a staging build (owner's Mac)

```
cd ~/inferoid-src/public && git fetch && git checkout staging && git pull
cd apps/notes && ./build-app.sh && open build/Inferoid.app
```

The Business app builds on this checkout too (see the inferoid-business repo).

## Release

1. Open a PR `staging` → `main`, wait for CI, merge.
2. Tag the release on `main`: `git tag notes-vX.Y.Z && git push origin notes-vX.Y.Z`.
   CI builds `Inferoid.zip` with its SHA-256 and publishes the GitHub release; `inferoid add notes` installs it.
