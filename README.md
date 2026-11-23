# LiftMaster — versions publiées

Ce dépôt ne contient aucun code source : il distribue les mises à jour des installations LiftMaster. Tout y est publié par les workflows du dépôt de développement (privé).

- **Releases**
  - `v<version>` : le paquet serveur `liftmaster-<version>.tar.gz`, installé par l'agent de chaque Raspberry Pi ;
  - `coquille-v<version>` : les fichiers de mise à jour de l'application des postes et leur `latest.json`, distribués aux postes par le Pi de leur atelier ;
  - `client-windows-N`, `client-rpi-N` : les installateurs de l'application, pour la première installation d'un poste.
- **GitHub Pages** (branche `gh-pages`) : les manifestes `beta.json` et `stable.json`, leurs signatures `.sig`, et `installer.sh`.

Les manifestes sont signés (ed25519) avec une clé qui n'est pas ici, et ils portent l'empreinte sha256 de chaque paquet : un fichier modifié dans ce dépôt est refusé par les Pi.

## Promouvoir une version

Quand une version publiée sur beta a fait ses preuves : **Actions > Promouvoir une version > Run workflow**, en saisissant la version (par exemple `1.3.0`). Le workflow copie `beta.json` et sa signature vers `stable.json` ; les Pi du canal stable l'installent dans leur fenêtre de mise à jour.

## Installer un Raspberry Pi neuf

```bash
curl -fsSL https://fabienbounoir.github.io/lift-releases/installer.sh | sudo bash
```
