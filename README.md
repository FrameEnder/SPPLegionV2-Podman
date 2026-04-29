<h1 align="center">
  <br>
  <a href="https://github.com/FrameEnder/SPPLegionV2-Podman"><img src="https://github.com/FrameEnder/SPPLegionV2-Podman/blob/main/Meta/SPPLegionV2.png" width="420"></a>
  <br>
  <b>SPPLegionV2-Podman</b>
  <br>
  <p>A Script For Installing, and Managing SPPLegionV2 in Podman</p>
</h1>

<h1 align="center">
 <a href="https://github.com/FrameEnder/SPPLegionV2-Podman/releases/latest">
        <img src="https://img.shields.io/badge/Download-Latest-green" width="140">
</h1>

<p align="center">
  <a href="https://raw.githubusercontent.com/FrameEnder/SPPLegionV2-Podman/refs/heads/main/Meta/1.png">
  <img src="https://github.com/FrameEnder/SPPLegionV2-Podman/blob/main/Meta/1.png" width="800">
    <br>
  <a href="https://raw.githubusercontent.com/FrameEnder/SPPLegionV2-Podman/refs/heads/main/Meta/2.png">
  <img src="https://github.com/FrameEnder/SPPLegionV2-Podman/blob/main/Meta/2.png" width="400">
</p>

# Features

* Stable Deployment
* Full CLI Launcher / Management Utility
* Account Management
* Character Save Manager
* Config Access
* Tailscale Integration


# How to Install 

Requirements

* Podman Installed
* 7z (Or any tool that can extract tar.gz)
* SPPLegionV2
* Tailscale Account (For IPv4 Routing)

1) Once you have all the requirements, Place the archive tar.gz anywhere on your PC / Server. Then simply extract the contents perferably into an Empty Folder with your tool of choice.
<br>
<p align="Left">
  <a href="https://raw.githubusercontent.com/FrameEnder/SPPLegionV2-Podman/refs/heads/main/Meta/Tutorial/1.png">
  <img src="https://github.com/FrameEnder/SPPLegionV2-Podman/blob/main/Meta/Tutorial/1.png" width="400">
  </a>
</p>

2) Now Right Click inside the folder containing ```spp-manage.sh```, and click ```Open Terminal Here```, or CD into that Folder in the Terminal
<br>
<p align="Left">
  <a href="https://raw.githubusercontent.com/FrameEnder/SPPLegionV2-Podman/refs/heads/main/Meta/Tutorial/2.png">
  <img src="https://github.com/FrameEnder/SPPLegionV2-Podman/blob/main/Meta/Tutorial/2.png" width="400">
  </a>
</p>

3) Once inside run ```./spp-manage.sh set-path <path>``` for example ```./spp-manage.sh set-path "/home/ProtoPropski/Servers/Games/World of Warcraft/Legion/SPP-LegionV2"``` this will be the location of your SPPLegionV2 Server Folder containing all your .bat files like ```Update.bat```, ```1_Database+Web.bat```, ```2_Bnetserver.bat```, and ```3_Worldserver.bat```
<br>
<p align="Left">
  <a href="https://raw.githubusercontent.com/FrameEnder/SPPLegionV2-Podman/refs/heads/main/Meta/Tutorial/3.png">
  <img src="https://github.com/FrameEnder/SPPLegionV2-Podman/blob/main/Meta/Tutorial/3.png" width="400">
  <a href="https://raw.githubusercontent.com/FrameEnder/SPPLegionV2-Podman/refs/heads/main/Meta/Tutorial/4.png">
  <img src="https://github.com/FrameEnder/SPPLegionV2-Podman/blob/main/Meta/Tutorial/4.png" width="400">
  </a>
</p>


4) ATM tailscale is required for IPv4 Routing, so you will need a Free Account, and to have Tailscale on your Client PC for connection, after making one goto https://login.tailscale.com/admin/settings/keys to create an Auth Key should start with ```tskey-auth-######```
then use ```./spp-manage.sh set-ts-key <key>``` with your authkey replacing <key> 
<br>
5) Now use ```./spp-manage.sh``` this will open the CLI Menu
<br>
<p align="Left">
  <a href="https://raw.githubusercontent.com/FrameEnder/SPPLegionV2-Podman/refs/heads/main/Meta/Tutorial/5.png">
  <img src="https://github.com/FrameEnder/SPPLegionV2-Podman/blob/main/Meta/Tutorial/5.png" width="400">
  </a>
</p>

6) Choose ```1 - Start Server``` in the menu it will start creating the Podman Images and populating them with all the required dependencies, this will take awhile, but you should see some connection settings when everything is done the blue globe icon will be your server IP, as well as your Database Connection IP
<br>
7) you will need to close, and re-open the ```./spp-manage.sh``` this won't turn off your server, now goto ```3 - Server Settings``` > ```2 - Edit bnetserver.conf``` then scroll down till you the LoginREST credentials change 127.0.0.1 to your Server IPv4 from Tailscale found on the main menu, or at the previous server start screen
<br>
<p align="Left">
  <a href="https://raw.githubusercontent.com/FrameEnder/SPPLegionV2-Podman/refs/heads/main/Meta/Tutorial/6.png">
  <img src="https://github.com/FrameEnder/SPPLegionV2-Podman/blob/main/Meta/Tutorial/6.png" width="400">
  </a>
</p>

8) also utilize a SQL Database tool of choice to edit the last 2 IP Entries making sure to Login with the IP we previously found, using the default credentials ```username - spp_user```, and ```password - 123456``` then find realmlist, and use ```SELECT * FROM `realmlist` LIMIT 1``` to query the first realm ```Single Player Project``` change the ```address```, and ```localAddress``` from 127.0.0.1 to your IPv4 address from Tailscale we found earlier those should save automatically just close your SQL Database tool of choice
<br>
<p align="Left">
  <a href="https://raw.githubusercontent.com/FrameEnder/SPPLegionV2-Podman/refs/heads/main/Meta/Tutorial/7.png">
  <img src="https://github.com/FrameEnder/SPPLegionV2-Podman/blob/main/Meta/Tutorial/7.png" width="400">
  </a>
</p>

9) once that is done go back to your terminal, and run ```./spp-manage.sh restart```, and that will restart your server with those IPv4 Addresses
<br>
10) then just open your ```config.wtf``` in your WoW 7.3.5 client, and change the portal entry from 127.0.0.1 to your IPv4, and your Ready to Go
<br>
<p align="Left">
  <a href="https://raw.githubusercontent.com/FrameEnder/SPPLegionV2-Podman/refs/heads/main/Meta/Tutorial/8.png">
  <img src="https://github.com/FrameEnder/SPPLegionV2-Podman/blob/main/Meta/Tutorial/8.png" width="400">
  </a>
</p>

# Commands

── Interactive ───────────────────────────────────────
<br>
<br>
  ```menu```                   - Full interactive launcher (default)
<br>
  ```servers```                - Server manager submenu
<br>
  ```settings```               - Realm name, edit conf files
<br>
  ```accounts```               - Create/list/GM accounts
<br>
  ```saves```                  - Save/load/delete DB snapshots (9 slots)
<br>
  ```realm```                  - Quick realm name change
<br>
<br>
── Container Control ─────────────────────────────────
<br>
<br>
  ```start```                  - Start all containers
<br>
  ```stop```                   - Stop all containers
<br>
  ```restart```                - Stop then start
<br>
  ```status```                 - Show container status
<br>
  ```logs [name]```            - Show/follow logs
<br>
  ```rebuild```                - Rebuild all images from scratch
<br>
<br>
── Configuration ─────────────────────────────────────
<br>
<br>
  ```set-path <path>```        - Path to SPP server files
<br>
  ```set-ts-key <key>```       - Tailscale pre-auth key
<br>
  ```set-ts-hostname <n>```    - Tailscale node name
<br>
  ```set-ip <IPv4>```          - Macvlan pod IP
<br>
  ```set-iface <nic>```        - Host NIC for macvlan
<br>
<br>
── Database ──────────────────────────────────────────
<br>
<br>
  ```fix-db [file.sql]```      - Create missing legion_auth tables
<br>
  ```fix-proc```               - Fix mysql.proc column mismatch (run if saves/backup fail)
<br>
  ```grant-local```            - Grant spp_user local socket access to all databases
<br>
  ```update```                 - Download and apply latest SPP-LegionV2 server update
<br>
  ```sql-import [file]```      - Run a custom .sql file against any SPP database
<br>
  ```upgrade-db```             - Run mariadb-upgrade on system tables
<br>
  ```ts-ip```                  - Show Tailscale IP
<br>
  ```ts-login```               - Interactive Tailscale login
