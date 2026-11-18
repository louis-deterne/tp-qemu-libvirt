# TP QEMU / KVM / libvirt — Environnement de virtualisation et mini-lab isolé

Auteur : Louis Deterne — La Plateforme

## 1. Objectif

Mettre en place une pile de virtualisation complète (QEMU, KVM, libvirt, virt-manager), construire un réseau virtuel isolé, déployer des VM de façon automatisée (cloud-init, virt-install) et mettre en œuvre un mini-lab attaquant / victime afin de manipuler l'isolation, les snapshots et la remédiation après incident.

| Composant | Rôle |
|---|---|
| **QEMU** | Émulateur / moteur de virtualisation (exécute les VM) |
| **KVM** | Module du noyau Linux qui fournit l'accélération matérielle (Intel VT-x / AMD-V) |
| **libvirt** | API et démon de gestion (`virsh`, réseaux, stockage, snapshots) |
| **virt-manager** | Interface graphique au-dessus de libvirt |
| **cloud-init** | Provisioning automatique des VM au premier démarrage |

## 2. Architecture

```
PC Windows 11 (Intel Core Ultra 7 265K, 32 Go)
└── VMware Workstation Pro 26H1  (virtualisation imbriquée VT-x/EPT activée)
    └── Ubuntu Desktop 24.04  = hyperviseur KVM  (16 Go RAM, 6 vCPU, 100 Go)
        └── libvirt / QEMU-KVM
            └── Réseau "lab-isolated"  10.10.10.0/24  (bridge virbr-lab, SANS accès Internet)
                ├── vm-test  10.10.10.158  Ubuntu 22.04 cloud image (cloud-init)
                ├── kali     10.10.10.106  Kali Linux 2026.3 (poste attaquant)
                └── msf2     10.10.10.120  Metasploitable2 (cible volontairement vulnérable)
```

| VM | Rôle | IP | MAC | RAM / vCPU | Carte réseau | Disque |
|---|---|---|---|---|---|---|
| vm-test | VM provisionnée par cloud-init | 10.10.10.158 | 52:54:00:97:6e:a3 | 2 Go / 2 | virtio | qcow2 (backing file) |
| kali | Attaquant | 10.10.10.106 | 52:54:00:f6:ab:f0 | 4 Go / 2 | virtio | qcow2 |
| msf2 | Cible vulnérable | 10.10.10.120 | 52:54:00:7f:ef:e6 | 1 Go / 1 | e1000 | qcow2 (converti depuis VMDK), bus IDE |
| *(hôte)* | Passerelle du lab | 10.10.10.1 | — | — | — | — |

> Les IP sont attribuées par le DHCP de libvirt et peuvent changer après un redéploiement.
> Pour identifier une VM de façon fiable, on utilise son **adresse MAC** (les noms `vnetX` changent à chaque démarrage).

## 3. Arborescence du dépôt

```
tp-qemu-libvirt/
├── README.md
├── .gitignore                 # exclut les disques (*.qcow2, *.img, *.iso, *.vmdk, archives)
├── network/
│   └── lab-isolated.xml       # définition du réseau isolé
├── cloud-init/
│   ├── user-data              # utilisateur, clé SSH publique, sudo
│   └── meta-data              # instance-id, hostname
├── vms/
│   ├── vm-test.xml            # dumpxml des VM
│   ├── kali.xml
│   └── msf2.xml
└── scripts/
    ├── deploy-vm-test.sh      # déploiement automatisé de vm-test
    └── remediate.sh           # remédiation : isolement, preuve, restauration
```

## 4. Installation de la pile de virtualisation

### 4.1 Vérifications préalables

```bash
egrep -c '(vmx|svm)' /proc/cpuinfo    # > 0 : le CPU expose la virtualisation
ls -l /dev/kvm                        # le périphérique KVM existe
kvm-ok                                # "KVM acceleration can be used"
```

### 4.2 Installation

```bash
sudo apt install -y qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients \
  virtinst virt-manager bridge-utils cloud-image-utils cpu-checker libguestfs-tools
sudo usermod -aG libvirt,kvm $USER          # puis déconnexion / reconnexion
sudo systemctl enable --now libvirtd
echo 'export LIBVIRT_DEFAULT_URI=qemu:///system' >> ~/.bashrc
virsh list --all
```

> Sur Ubuntu 24.04, `qemu-kvm` n'est plus qu'un paquet virtuel : il faut installer explicitement `qemu-system-x86`.

## 5. Réseau virtuel isolé

`network/lab-isolated.xml` :

```xml
<network>
  <name>lab-isolated</name>
  <bridge name="virbr-lab"/>
  <ip address="10.10.10.1" netmask="255.255.255.0">
    <dhcp>
      <range start="10.10.10.100" end="10.10.10.200"/>
    </dhcp>
  </ip>
</network>
```

```bash
virsh net-define network/lab-isolated.xml
virsh net-start lab-isolated
virsh net-autostart lab-isolated
virsh net-list --all
```

**Choix de conception :** le réseau ne contient **aucune balise `<forward>`**. Contrairement au réseau `default` (`<forward mode="nat"/>`), libvirt ne crée ni NAT ni routage vers l'extérieur, et le DHCP ne distribue **aucune passerelle par défaut**. Les VM ne peuvent communiquer qu'entre elles et avec l'hôte.

**Vérification (depuis vm-test) :**

```
$ ping 8.8.8.8
ping: connect: Network is unreachable      -> aucune route vers l'extérieur
$ ping 10.10.10.1
64 bytes from 10.10.10.1 ...               -> le réseau du lab fonctionne
$ ip route
10.10.10.0/24 dev enp1s0 ...               -> pas de ligne "default via"
```

C'est ce qui permet d'héberger une machine volontairement vulnérable (Metasploitable2) sans l'exposer : même compromise, elle ne peut rien atteindre hors du lab.

## 6. Déploiement automatisé (cloud-init + virt-install)

### 6.1 Principe

- Image de base : Ubuntu 22.04 *cloud image* (`jammy-server-cloudimg-amd64.img`), jamais modifiée.
- Disque de la VM : *overlay* qcow2 qui ne stocke que les différences avec l'image de base (`qemu-img create -b ...`).
- Configuration (utilisateur, clé SSH, hostname) injectée au premier démarrage via un ISO *NoCloud* généré par `cloud-localds`.
- Authentification **par clé uniquement** (`lock_passwd: true`) : aucun mot de passe, même en console.

### 6.2 Script `scripts/deploy-vm-test.sh`

Le script redéploie vm-test de zéro en une commande :
1. génère `user-data` (avec la clé publique courante) et `meta-data` (instance-id unique) ;
2. supprime l'ancienne VM et son disque s'ils existent ;
3. crée un nouveau disque overlay et l'ISO cloud-init (`cloud-localds`) ;
4. crée la VM avec `virt-install` sur le réseau `lab-isolated`.

```bash
./scripts/deploy-vm-test.sh
virsh net-dhcp-leases lab-isolated
ssh labadmin@<IP>
```

### 6.3 Import de Kali et Metasploitable2

```bash
IMG=/var/lib/libvirt/images
# Kali : image QEMU officielle (déjà en qcow2)
sudo mv kali-linux-2026.3-qemu-amd64.qcow2 $IMG/kali.qcow2
# Metasploitable2 : conversion VMDK (VMware) -> qcow2 (KVM) pour permettre les snapshots
sudo qemu-img convert -p -f vmdk -O qcow2 Metasploitable.vmdk $IMG/msf2.qcow2

virt-install --name kali --memory 4096 --vcpus 2 --disk $IMG/kali.qcow2 --import \
  --network network=lab-isolated --os-variant debian12 --graphics spice --noautoconsole

virt-install --name msf2 --memory 1024 --vcpus 1 --disk $IMG/msf2.qcow2,bus=ide --import \
  --network network=lab-isolated,model=e1000 --os-variant generic --graphics spice --noautoconsole
```

**Choix pour msf2 :** système très ancien (Ubuntu 8.04) → disque en **IDE** et carte réseau **e1000** émulée, au lieu des pilotes paravirtualisés virtio qu'il ne sait pas gérer.

**Vérification de l'isolation :**

```bash
virsh domiflist kali    # Source : lab-isolated
virsh domiflist msf2    # Source : lab-isolated
```

## 7. Snapshots

Avant toute manipulation, un snapshot « état sain » est pris pour chaque VM du lab :

```bash
virsh snapshot-create-as kali clean "Etat sain - avant tests"
virsh snapshot-create-as msf2 clean "Etat sain - avant tests"
virsh snapshot-list msf2
```

Les snapshots internes (disque + mémoire) nécessitent le format **qcow2**, d'où la conversion du disque VMDK de Metasploitable2.

## 8. Mesure du niveau de sécurité (C8)

### 8.1 Audit de l'hyperviseur

```bash
sudo virt-host-validate qemu      # conformité de l'hôte KVM
sudo lynis audit system           # audit de durcissement de l'hôte
```

| Indicateur | Avant | Après corrections |
|---|---|---|
| Lynis — Hardening index | 61 / 100 | 71 / 100 |
| Tests réalisés | 253 | 262 |
| Scanner de malware (rkhunter) | Absent `[X]` | Présent `[V]` |

Rapports conservés dans le dépôt : `audit/lynis-avant.dat` et `audit/lynis-apres.dat`.

Corrections appliquées suite à l'audit (hôte KVM) :

| Recommandation Lynis | Action réalisée | Justification |
|---|---|---|
| Malware scanner absent | Installation de **rkhunter** | Détection de rootkits sur l'hôte |
| DEB-0880 | Installation de **fail2ban** | Bannit les IP après plusieurs échecs d'authentification |
| ACCT-9628 | Activation d'**auditd** | Journalisation des événements de sécurité |
| FINT-4350 | Installation d'**AIDE** | Surveille l'intégrité des fichiers critiques (lien avec C10) |
| BANN-7126 / 7130 | Bannières légales sur `/etc/issue` et `/etc/issue.net` | Avertit tout accès non autorisé |
| AUTH-9328 / 9286 | `UMASK 027`, politique d'âge des mots de passe (`PASS_MAX_DAYS`, `PASS_MIN_DAYS`) | Permissions et mots de passe plus stricts par défaut |
| KRNL-5820 / NETW-3200 | Désactivation des core dumps et des protocoles réseau inutiles (dccp, sctp, rds, tipc) | Réduit la surface d'attaque |
| Durcissement SSH | `PermitRootLogin no`, `PasswordAuthentication no`, `MaxAuthTries 3` | Authentification par clé uniquement |
| Pare-feu | Activation d'**UFW** (deny incoming, allow ssh) | Filtrage des connexions entrantes sur l'hôte |

**Pistes identifiées non appliquées** (hors périmètre d'un lab, citées pour exhaustivité) : mot de passe GRUB (BOOT-5122) et partitions séparées pour `/home`, `/tmp`, `/var` (FILE-6310).

### 8.2 Évaluation de la cible du lab

**Périmètre :** réseau `lab-isolated` (10.10.10.0/24) uniquement. Isolation vérifiée au préalable (section 5) et snapshots `clean` pris (section 7).

**Méthode et outils :** découverte des hôtes et inventaire des services/versions depuis Kali, puis corrélation des versions avec les vulnérabilités connues. Confirmation manuelle d'un accès sur la cible Metasploitable2.

**Résultats :**

| Service / port | Vulnérabilité / faiblesse | Gravité | Recommandation |
|---|---|---|---|
| ingreslock / 1524 | Backdoor (bind shell) : accès shell distant **sans authentification** — accès confirmé depuis Kali | Critique | Fermer le port, supprimer le service, filtrer par pare-feu |
| _(autres services inventoriés à compléter)_ | | | |

**Synthèse :** Metasploitable2 est une cible volontairement vulnérable. L'accès au port 1524 a été confirmé et donne un shell distant sans authentification, ce qui illustre une faille critique. Cet accès constitue l'incident traité en section 9 (C10).

## 9. Détection et traitement d'un incident (C10)

### 9.1 Scénario

Un incident est simulé sur msf2 (dépôt d'un fichier `INCIDENT.txt` dans le répertoire utilisateur) et/ou constaté suite aux tests de la section 8.

### 9.2 Procédure (`scripts/remediate.sh`)

```bash
./scripts/remediate.sh msf2 clean
```

| Étape | Action | Commande clé |
|---|---|---|
| 1. Isolement | Coupure du lien réseau de la VM pour stopper toute propagation | `virsh domif-setlink msf2 <MAC> down` |
| 2. Preuve | Conservation de l'état compromis dans un snapshot daté, pour analyse ultérieure | `virsh snapshot-create-as msf2 incident-<date>` |
| 3. Restauration | Retour à l'état sain | `virsh snapshot-revert msf2 clean --running` |
| 4. Vérification | Contrôle de l'état de la VM ; elle reste isolée jusqu'à validation | `virsh domstate`, `domif-getlink` |
| 5. Reconnexion | Après validation manuelle | `virsh domif-setlink msf2 <MAC> up` |

**Point d'attention :** `snapshot-revert` restaure aussi la configuration réseau du snapshot (lien actif). Le script recoupe donc le lien juste après la restauration, afin que la VM ne soit reconnectée qu'après vérification.

### 9.3 Résultat

- Avant : `INCIDENT.txt` présent sur msf2.
- Après : le fichier a disparu, la VM est revenue à l'état `clean`, et l'état compromis reste disponible pour analyse (`incident-<date>`).

## 10. Difficultés rencontrées et résolutions

| # | Symptôme | Cause identifiée | Résolution |
|---|---|---|---|
| 1 | KVM/libvirt indisponibles sous Windows | KVM est un module du noyau Linux | Hyperviseur Ubuntu dans une VM VMware avec virtualisation imbriquée |
| 2 | VMware plante au lancement d'une VM KVM : `vcpu-0 Exception 0x80000003` | Conflit avec l'hyperviseur Windows (Hyper-V / VBS) | Mise à jour de VMware (26H1) |
| 3 | « Intel VT-x/EPT virtualisé n'est pas pris en charge sur cette plate-forme » | Sécurité basée sur la virtualisation (VBS) toujours active | Désactivation de l'intégrité mémoire, des fonctionnalités Hyper-V/WHP/VMP, `bcdedit /set hypervisorlaunchtype off`, clés DeviceGuard ; vérification dans `msinfo32` |
| 4 | `Package 'qemu-kvm' has no installation candidate` | Paquet devenu virtuel sous Ubuntu 24.04 | Installation de `qemu-system-x86` |
| 5 | VM sans IP après le plantage VMware | Premier démarrage interrompu, cloud-init non terminé | Redéploiement complet (intérêt de l'automatisation) |
| 6 | `Permission denied (publickey)` alors que la clé dans `user-data` est correcte | `useradd: group admin exists` : l'image Ubuntu contient déjà un groupe `admin`, la création de l'utilisateur échoue | Diagnostic hors-ligne avec `virt-cat` (`/etc/passwd`, `/var/log/cloud-init.log`) ; utilisateur renommé `labadmin` |
| 7 | ISO cloud-init temporaire de virt-install introuvable (`virt-cat -d`) | virt-install supprime son ISO temporaire après la création | ISO NoCloud généré et géré par le script avec `cloud-localds` |

**Démarche retenue :** symptôme → hypothèse → vérification → cause → correctif. Exemple sur la difficulté n°6 : les clés étant identiques, l'hypothèse « mauvaise clé » a été écartée ; la lecture du disque de la VM avec `virt-cat` a montré que l'utilisateur n'existait pas, puis le log cloud-init a donné la cause exacte.

## 11. Compétences mobilisées

| Compétence | Mise en œuvre dans ce TP |
|---|---|
| BC01·C4 — Administrer et sécuriser une infrastructure virtualisée | Installation QEMU/KVM/libvirt, gestion des VM, formats qcow2, snapshots, accès SSH par clé uniquement |
| BC01·C1 — Bonnes pratiques d'administration | Vérifications préalables (`kvm-ok`, `msinfo32`), documentation, versionnement Git, `.gitignore`, diagnostic méthodique |
| BC01·C2 — Réseaux virtuels isolés | Réseau `lab-isolated` sans `<forward>`, vérification par `ping` / `ip route`, `domiflist` |
| BC02·C5 / C6 — Automatisation | `cloud-init`, `cloud-localds`, `virt-install`, scripts `deploy-vm-test.sh` et `remediate.sh` |
| BC03·C8 — Mesurer le niveau de sécurité | Audit de l'hôte (Lynis, `virt-host-validate`), évaluation de la cible du lab (section 8) |
| BC03·C10 — Détecter et traiter un incident | Procédure isolement → preuve → restauration → vérification par snapshots |

## 12. Sécurité et bonnes pratiques

- Metasploitable2 n'est connectée **qu'au réseau isolé**, jamais au réseau `default` (NAT).
- Les disques de VM ne sont pas versionnés (`.gitignore`). Seule la **clé publique** SSH figure dans `user-data` ; la clé privée ne quitte pas l'hôte.
- Identifiants par défaut de Kali (`kali/kali`) et Metasploitable2 à ne jamais réutiliser hors du lab.
- Les réglages de sécurité Windows désactivés pour la virtualisation imbriquée (intégrité mémoire, VBS, Hyper-V) sont à réactiver à la fin du projet (`bcdedit /set hypervisorlaunchtype auto`).

## 13. Reproduire le lab

```bash
git clone https://github.com/louis-deterne/tp-qemu-libvirt.git && cd tp-qemu-libvirt
virsh net-define network/lab-isolated.xml && virsh net-start lab-isolated
# placer jammy-server-cloudimg-amd64.img dans /var/lib/libvirt/images
./scripts/deploy-vm-test.sh
```

## Sources

- Documentation QEMU : https://www.qemu.org/docs/master/
- Documentation KVM : https://linux-kvm.org
- Documentation libvirt (réseaux, snapshots) : https://libvirt.org/docs.html
- virt-manager : https://virt-manager.org
- cloud-init (NoCloud, users) : https://cloudinit.readthedocs.io
- Kali Linux (images VM) : https://www.kali.org/get-kali/
- Metasploitable2 : https://sourceforge.net/projects/metasploitable/
