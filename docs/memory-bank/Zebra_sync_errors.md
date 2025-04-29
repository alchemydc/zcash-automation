# Zebra sync errors

```
Apr 26 12:25:20 zebra-archivenode zebrad[11843]: 2025-04-26T12:25:20.166899Z  WARN {zebrad="6d01f05" net="Main"}:sync:try_to_sync:try_to_sync_once{extra_hashes={}}: zebrad::components::sync: error downloading and verifying block e=ValidationRequestError { error: Elapsed(()), height: Height(1744431), hash: block::Hash("000000000147c56445e872dffe844f759ff011f520be867b6b6f330df60ed187") }
Apr 26 12:25:20 zebra-archivenode zebrad[11843]: 2025-04-26T12:25:20.167701Z  INFO {zebrad="6d01f05" net="Main"}:sync: zebrad::components::sync: waiting to restart sync timeout=67s state_tip=Some(Height(1739400))
Apr 26 12:25:29 zebra-archivenode zebrad[11843]: 2025-04-26T12:25:29.584874Z  INFO {zebrad="6d01f05" net="Main"}: zebrad::components::sync::progress: estimated progress to chain tip sync_percent=59.798% current_height=Height(1739408) network_upgrade=Nu5 remaining_sync_blocks=1169412 time_since_last_state_block=0s
```
