# surrogate-1 runtime state

Auto-synced by state-sync-daemon every 300s. Restoring a VM:
```
git clone -b state https://github.com/arkashira/surrogate-1-harvest.git
rsync -a state-snapshot/ /opt/surrogate-1-harvest/state/
```
Latest sync timestamp lives in .last-sync.
