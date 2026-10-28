#!/bin/bash
# Installe LiftMaster sur un Raspberry Pi depuis un paquet (tar.gz), ou bascule
# un Pi installé à l'ancienne (git pull + deploy.sh) vers les mises à jour
# automatiques. À lancer avec sudo, depuis le compte qui fait tourner LiftMaster.
#
# Pi neuf, sans rien d'autre que ce script (il est publié sous le nom
# installer.sh à côté des manifestes) :
#   curl -fsSL https://fabienbounoir.github.io/lift-releases/installer.sh | sudo bash
#   curl -fsSL https://fabienbounoir.github.io/lift-releases/installer.sh | sudo bash -s -- --depuis /home/liftmaster/lift
#
# Depuis un dépôt ou un paquet :
#   sudo scripts/installer-paquet.sh                      dernière version « stable »
#   sudo scripts/installer-paquet.sh liftmaster-1.2.0.tar.gz | https://...tar.gz
#   sudo scripts/installer-paquet.sh --depuis /home/liftmaster/lift [paquet]
#
# --depuis <ancien dépôt> copie <ancien>/data/ vers /var/lib/liftmaster (si
# celui-ci est vide) et <ancien>/.env vers /etc/liftmaster/liftmaster.env, puis
# remplace l'ancienne unité liftmaster-backend. L'ancien dépôt n'est jamais
# supprimé : c'est le retour arrière.
#
# --sans-systeme saute scripts/preparer-systeme.sh (ffmpeg, voix Piper, journal
# persistant, watchdog) : pour les tests, ou un Pi déjà préparé.
#
# Sans argument paquet, la version « stable » est celle d'un manifeste signé
# (ed25519), vérifié avec la clé publique embarquée ci-dessous avant de faire
# confiance à l'URL qu'il contient. Avec un chemin ou une URL explicite, c'est
# l'opérateur qui garantit le paquet.
#
# Idempotent : relancé, il réinstalle les unités et relance le service.
set -euo pipefail

# Clé publique des manifestes (la privée vit dans le secret GitHub
# LIFTMASTER_SIGNING_KEY). Même clé que CLE_PUBLIQUE dans agent/agent.js ; un
# test garde les deux alignées. Surchargeable pour les tests, comme l'agent.
# ponytail: clé dupliquée plutôt que lue dans agent.js, car le script tourne seul
# (curl | bash) et la vérification doit précéder le téléchargement du paquet.
# Un manifeste signé ancien rejoué installerait une vieille version : pas de
# date d'expiration, même limite que l'agent.
CLE_PUBLIQUE_DEFAUT='-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAb9Rlxg34Dzbj7oc3Dlh70VBZTAzEYqpfGv8/RDJ92dU=
-----END PUBLIC KEY-----'
CLE_PUBLIQUE="${LIFTMASTER_CLE_PUBLIQUE:-$CLE_PUBLIQUE_DEFAUT}"

# Surcharges pour les tests (le script tourne sinon avec les chemins du contrat).
RACINE="${LIFTMASTER_RACINE:-/opt/liftmaster}"
DATA_DIR="${DATA_DIR:-/var/lib/liftmaster}"
DOSSIER_ENV="${LIFTMASTER_ETC:-/etc/liftmaster}"
DOSSIER_UNITES="${LIFTMASTER_UNITES:-/etc/systemd/system}"
URL_MANIFESTES="${LIFTMASTER_URL_MANIFESTES:-https://fabienbounoir.github.io/lift-releases}"
PORT="${PORT:-3000}"

# Vide quand le script arrive par un tube (curl ... | sudo bash) : il n'a alors
# pas de dossier « à côté de lui ». Surtout pas le dossier courant : y chercher
# un script à lancer en root, c'est l'offrir à qui y dépose un fichier.
SCRIPT_FILE="${BASH_SOURCE[0]:-}"
SCRIPT_DIR=""
if [[ -f "$SCRIPT_FILE" ]]; then
	SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_FILE")" && pwd)"
fi

# Tout le script est dans main, appelée tout en bas : bash lit donc le script
# en entier avant d'exécuter quoi que ce soit. Sans cela, avec `curl | sudo
# bash`, une commande qui lit l'entrée standard (apt-get, un installeur) avale
# la suite du script, qui s'arrête alors n'importe où.
main() {
	ANCIEN=""
	SOURCE=""
	SANS_SYSTEME=0

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--depuis)
			ANCIEN="${2:?--depuis demande le dossier de la vieille installation}"
			shift 2
			;;
		--sans-systeme)
			SANS_SYSTEME=1
			shift
			;;
		-h | --help)
			sed -n '2,/^set -/p' "${SCRIPT_FILE:-/dev/null}" | sed -e '$d' -e 's/^# \{0,1\}//'
			exit 0
			;;
		*)
			SOURCE="$1"
			shift
			;;
		esac
	done

	echo "🍓 Installation LiftMaster (paquet) sur Raspberry Pi"
	echo "===================================================="

	if [[ "$EUID" -ne 0 && "${LIFTMASTER_SANS_ROOT:-}" != "1" ]]; then
		echo "❌ Ce script doit être lancé avec sudo : sudo scripts/installer-paquet.sh" >&2
		exit 1
	fi

	SERVICE_USER="${SERVICE_USER:-${SUDO_USER:-}}"
	if [[ -z "$SERVICE_USER" || "$SERVICE_USER" == "root" ]]; then
		echo "❌ Lancez-le avec sudo depuis le compte qui fait tourner LiftMaster (pas en root direct)." >&2
		exit 1
	fi
	SERVICE_GROUP="$(id -gn "$SERVICE_USER")"

	# --- Node.js -----------------------------------------------------------------
	# Même résolution que install-rpi.sh : on réutilise le node du Pi (n, nvm, apt),
	# qui vit souvent dans le HOME de l'utilisateur et pas dans le PATH de root.
	# Avant tout le reste : la vérification de signature en a besoin.
	resolve_node() {
		local found
		found="$(command -v node || true)"
		if [[ -z "$found" ]]; then
			found="$(sudo -H -u "$SERVICE_USER" bash -ic 'command -v node' 2>/dev/null | tr -d '\r' | tail -1)"
		fi
		printf '%s' "$found"
	}

	NODE_BIN="$(resolve_node)"
	NODE_MAJOR=0
	[[ -n "$NODE_BIN" ]] && NODE_MAJOR="$("$NODE_BIN" -v | cut -d. -f1 | tr -d v)"

	if [[ -z "$NODE_BIN" || "$NODE_MAJOR" -lt 20 ]]; then
		echo "🟢 Installation de Node.js 20 (aucun node >= 20 trouvé)..."
		apt-get update
		curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
		apt-get install -y nodejs
		NODE_BIN=/usr/bin/node
	fi
	echo "✅ Node : $NODE_BIN ($("$NODE_BIN" -v))"

	# Lecture d'un champ d'un fichier JSON (chemin pointé), avec le node résolu ci-dessus.
	champ_json() {
		"$NODE_BIN" --input-type=module -e '
			import { readFileSync } from "node:fs";
			const valeur = process.argv[2].split(".").reduce((o, k) => o?.[k], JSON.parse(readFileSync(process.argv[1], "utf8")));
			console.log(valeur ?? "");
		' "$1" "$2"
	}

	# Signature ed25519 (base64) d'un fichier : code 0 si elle est valide pour la
	# clé publique, autre chose sinon (signature fausse, fichier modifié).
	verifier_signature() {
		"$NODE_BIN" -e '
			const crypto = require("node:crypto");
			const fs = require("node:fs");
			const [fichier, signature, cle] = process.argv.slice(1);
			const valide = crypto.verify(
				null,
				fs.readFileSync(fichier),
				crypto.createPublicKey(cle),
				Buffer.from(fs.readFileSync(signature, "utf8").trim(), "base64")
			);
			process.exit(valide ? 0 : 1);
		' "$1" "$2" "$CLE_PUBLIQUE"
	}

	# --- Récupération du paquet --------------------------------------------------
	TMP="$(mktemp -d)"
	trap 'rm -rf "$TMP"' EXIT
	PAQUET="$TMP/paquet.tar.gz"

	if [[ -z "$SOURCE" ]]; then
		echo "🌐 Recherche de la dernière version stable..."
		if ! curl -fsSL --max-time 30 "$URL_MANIFESTES/stable.json" -o "$TMP/stable.json" ||
			! curl -fsSL --max-time 30 "$URL_MANIFESTES/stable.json.sig" -o "$TMP/stable.json.sig"; then
			echo "❌ Manifeste stable injoignable ($URL_MANIFESTES) : pas de réseau, ou aucune version n'a encore été promue en stable." >&2
			exit 1
		fi

		# Le manifeste est vérifié AVANT de faire confiance à l'URL qu'il contient.
		if ! verifier_signature "$TMP/stable.json" "$TMP/stable.json.sig"; then
			echo "❌ Signature du manifeste stable invalide : installation refusée." >&2
			exit 1
		fi

		URL_PAQUET="$(champ_json "$TMP/stable.json" serveur.url)"
		SHA_ATTENDU="$(champ_json "$TMP/stable.json" serveur.sha256)"
		echo "⬇️  Téléchargement de $(champ_json "$TMP/stable.json" version)..."
		curl -fL --max-time 900 "$URL_PAQUET" -o "$PAQUET"
		if [[ "$(sha256sum "$PAQUET" | cut -d' ' -f1)" != "$SHA_ATTENDU" ]]; then
			echo "❌ Empreinte sha256 du paquet incorrecte : installation refusée." >&2
			exit 1
		fi
	elif [[ "$SOURCE" =~ ^https?:// ]]; then
		echo "⬇️  Téléchargement de $SOURCE..."
		curl -fL --max-time 900 "$SOURCE" -o "$PAQUET"
	elif [[ -f "$SOURCE" ]]; then
		PAQUET="$(cd "$(dirname "$SOURCE")" && pwd)/$(basename "$SOURCE")"
	else
		echo "❌ Paquet introuvable : $SOURCE" >&2
		exit 1
	fi

	# --- Arborescence ------------------------------------------------------------
	mkdir -p "$RACINE/releases" "$RACINE/agent" "$DOSSIER_ENV"

	echo "📦 Extraction du paquet..."
	STAGING="$RACINE/releases/.installation.tmp"
	rm -rf "$STAGING"
	mkdir -p "$STAGING"
	tar -xzf "$PAQUET" -C "$STAGING" --strip-components=1 --no-same-owner
	paquet_invalide() {
		rm -rf "$STAGING"
		echo "❌ Ce n'est pas un paquet LiftMaster valide." >&2
		exit 1
	}
	[[ -f "$STAGING/package.json" && -f "$STAGING/server.js" && -f "$STAGING/agent/agent.js" ]] || paquet_invalide
	VERSION="$(champ_json "$STAGING/package.json" version)"
	[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || paquet_invalide

	# Une version est immuable : si elle est déjà extraite (relance du script), on la garde.
	if [[ -d "$RACINE/releases/$VERSION" ]]; then
		echo "✅ Version $VERSION déjà extraite"
		rm -rf "$STAGING"
	else
		mv "$STAGING" "$RACINE/releases/$VERSION"
	fi
	DEST="$RACINE/releases/$VERSION"

	# --- Préparation du système --------------------------------------------------
	# ffmpeg, Piper et sa voix, journal persistant, watchdog : le même
	# scripts/preparer-systeme.sh que install-rpi.sh. Celui du paquet d'abord (c'est
	# la version qui s'installe), sinon celui qui est à côté de ce script. Avant la
	# bascule : la voix (~61 Mo) se télécharge pendant que l'ancien service tourne.
	if [[ "$SANS_SYSTEME" -eq 1 ]]; then
		echo "⏭️  Préparation du système ignorée (--sans-systeme)"
	else
		PREPARER=""
		for candidat in "$DEST/scripts/preparer-systeme.sh" "${SCRIPT_DIR:+$SCRIPT_DIR/preparer-systeme.sh}"; do
			if [[ -n "$candidat" && -f "$candidat" ]]; then
				PREPARER="$candidat"
				break
			fi
		done
		if [[ -n "$PREPARER" ]]; then
			SERVICE_USER="$SERVICE_USER" bash "$PREPARER"
		else
			echo "⚠️  preparer-systeme.sh introuvable : ffmpeg, voix, journal persistant et watchdog non vérifiés." >&2
		fi
	fi

	# --- Bascule depuis une installation à l'ancienne ---------------------------
	if [[ -n "$ANCIEN" ]]; then
		if [[ ! -d "$ANCIEN/data" ]]; then
			echo "❌ $ANCIEN/data introuvable : ce n'est pas l'ancien dépôt LiftMaster." >&2
			exit 1
		fi
		mkdir -p "$DATA_DIR"

		if [[ -z "$(ls -A "$DATA_DIR" 2>/dev/null)" ]]; then
			# Copie, jamais déplacement : l'ancien dépôt reste le retour arrière. On
			# vérifie la place avant d'arrêter le service, pas après.
			BESOIN_KO="$(du -sk "$ANCIEN/data" | cut -f1)"
			LIBRE_KO="$(df -Pk "$DATA_DIR" | awk 'NR==2 {print $4}')"
			if [[ "$LIBRE_KO" -lt $((BESOIN_KO + 512 * 1024)) ]]; then
				echo "❌ Pas assez de place pour copier les données (${BESOIN_KO} Ko à copier, ${LIBRE_KO} Ko libres)." >&2
				exit 1
			fi
			echo "🛑 Arrêt de l'ancien service, puis copie des données..."
			systemctl stop liftmaster-backend 2>/dev/null || true
			cp -a "$ANCIEN/data/." "$DATA_DIR/"
		else
			echo "⚠️  $DATA_DIR n'est pas vide : données non copiées (déjà basculé ?)"
			systemctl stop liftmaster-backend 2>/dev/null || true
		fi

		if [[ -f "$ANCIEN/.env" && ! -f "$DOSSIER_ENV/liftmaster.env" ]]; then
			# DATA_DIR est fixé par l'unité : un ancien .env qui le redéfinirait
			# (EnvironmentFile l'emporte sur Environment) renverrait vers l'ancien dossier.
			grep -v '^DATA_DIR=' "$ANCIEN/.env" >"$DOSSIER_ENV/liftmaster.env" || true
			echo "✅ Réglages locaux repris de $ANCIEN/.env"
		fi
	fi

	mkdir -p "$DATA_DIR"
	chown -R "$SERVICE_USER:$SERVICE_GROUP" "$DATA_DIR"
	# Lu par systemd (root) : les clés qu'il contient n'ont pas à être lisibles de tous.
	[[ -f "$DOSSIER_ENV/liftmaster.env" ]] || printf '# Reglages locaux de LiftMaster (cle meteo...), un NOM=valeur par ligne.\n' >"$DOSSIER_ENV/liftmaster.env"
	chmod 600 "$DOSSIER_ENV/liftmaster.env"

	# --- Version active, agent, unités ------------------------------------------
	ln -sfn "$DEST" "$RACINE/current"
	install -m 755 "$DEST/agent/agent.js" "$RACINE/agent/agent.js"

	echo "🔧 Installation des services systemd..."
	for unite in liftmaster-backend.service liftmaster-update.service; do
		sed -e "s|__SERVICE_USER__|${SERVICE_USER}|g" \
			-e "s|__NODE_BIN__|${NODE_BIN}|g" \
			"$DEST/deploy/$unite" >"$DOSSIER_UNITES/$unite"
	done
	cp "$DEST/deploy/liftmaster-update.timer" \
		"$DEST/deploy/liftmaster-health.service" \
		"$DEST/deploy/liftmaster-health.timer" "$DOSSIER_UNITES/"

	systemctl daemon-reload
	systemctl enable liftmaster-backend
	systemctl restart liftmaster-backend
	systemctl enable --now liftmaster-update.timer
	systemctl enable --now liftmaster-health.timer

	echo "⏳ Vérification du backend..."
	for _ in $(seq 1 20); do
		if curl -fsS --max-time 2 "http://localhost:$PORT/health" >/dev/null 2>&1; then
			echo "✅ Backend en ligne."
			break
		fi
		sleep 1
	done
	if ! curl -fsS --max-time 2 "http://localhost:$PORT/health" >/dev/null 2>&1; then
		echo "❌ Le backend ne répond pas : journalctl -u liftmaster-backend -n 50" >&2
		exit 1
	fi

	cat <<EOF

✅ LiftMaster $VERSION installé.

📋 Commandes utiles :
  - Statut       : systemctl status liftmaster-backend
  - Logs         : journalctl -u liftmaster-backend -f
  - Mises à jour : journalctl -u liftmaster-update -n 50   (lancer un passage : sudo systemctl start liftmaster-update)
  - Prochains passages : systemctl list-timers 'liftmaster-*'

📁 Code : $RACINE/current   Données : $DATA_DIR   Réglages locaux : $DOSSIER_ENV/liftmaster.env
EOF
	if [[ -n "$ANCIEN" ]]; then
		echo "ℹ️  L'ancien dépôt $ANCIEN est conservé (retour arrière). Vous pourrez le supprimer une fois la bascule validée."
	else
		echo "👉 Le garage se configure dans l'assistant (identité, ponts, services, mot de passe), sur le PC d'accueil."
	fi
}

main "$@"
