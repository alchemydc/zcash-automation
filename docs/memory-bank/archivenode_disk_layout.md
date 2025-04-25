# archivenode disk layout

* sda: 100G persistent (for chaindata)
* sdb: 2G for params (required?)
* sdc: 10G for boot/OS

## TODO:
* the persistent volume for chaindata needs to be much larger
* the params disk can likely go away (?)
* use flash for OS drive (?)

```
dc@zcash-archivenode:/etc/apt/sources.list.d$ sudo fdisk -l
Disk /dev/sda: 100 GiB, 107374182400 bytes, 209715200 sectors
Disk model: PersistentDisk
Units: sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 4096 bytes
I/O size (minimum/optimal): 4096 bytes / 4096 bytes


Disk /dev/sdc: 10 GiB, 10737418240 bytes, 20971520 sectors
Disk model: PersistentDisk
Units: sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 4096 bytes
I/O size (minimum/optimal): 4096 bytes / 4096 bytes
Disklabel type: gpt
Disk identifier: 2D96DDBE-A931-DA46-A1C7-6DE87BCD326D

Device      Start      End  Sectors  Size Type
/dev/sdc1  262144 20969471 20707328  9.9G Linux filesystem
/dev/sdc14   2048     8191     6144    3M BIOS boot
/dev/sdc15   8192   262143   253952  124M EFI System

Partition table entries are not in disk order.


Disk /dev/sdb: 2 GiB, 2147483648 bytes, 4194304 sectors
Disk model: PersistentDisk
Units: sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 4096 bytes
I/O size (minimum/optimal): 4096 bytes / 4096 bytes
```

