#!/usr/bin/env bash
# Launch Conquest of Azeroth client via Wine with DXVK overrides
WINEDLLOVERRIDES="d3d9=n,b" wine Ascension.exe "$@"
