#!/usr/bin/env bash
# Configure GitLab through its REST API: security settings, groups, users, roles, sample
# projects, protected branches, CI variable, and the group runner token. Run as root on the gitlab server.
# Generated passwords/tokens go to /root/lab-provision/ (mode 700), never to the repo or the terminal.
set -euo pipefail
FQDN=${FQDN:-gitlab.company.internal}
API="https://${FQDN}/api/v4"
CACERT=/etc/gitlab/trusted-certs/lab-ca.crt
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=/root/lab-provision
umask 077; mkdir -p "$OUT"
command -v jq >/dev/null || apt-get install -y jq

# ---- 0. Temporary admin token (2 days). Revoked at the end. ----------------------
CREATED_TOKEN=0
if [[ -z ${TOKEN:-} ]]; then
  echo "Creating a temporary admin token (the Rails console takes ~1 minute)..."
  TOKEN=$(gitlab-rails runner '
    u = User.find_by_username("root")
    t = u.personal_access_tokens.build(name: "provision", scopes: [:api, :create_runner], expires_at: 2.days.from_now)
    t.organization = Organizations::Organization.default_organization if t.respond_to?(:organization=) && defined?(Organizations::Organization)
    t.save!
    puts t.token' | tail -1)
  CREATED_TOKEN=1
fi

api() { local m=$1 p=$2; shift 2; curl -fsS --cacert "$CACERT" -X "$m" -H "PRIVATE-TOKEN: $TOKEN" "${API}${p}" "$@"; }
enc() { printf '%s' "${1//\//%2F}"; }
randpw() { openssl rand -base64 24 | tr -d '/+=' | cut -c1-20; }

# ---- 1. Instance-wide security settings ---------------------------------------------
# signup off | 2FA required for everyone (24 h grace to enrol) | new projects/groups private | public visibility forbidden
api PUT /application/settings \
  --data signup_enabled=false \
  --data require_two_factor_authentication=true \
  --data two_factor_grace_period=24 \
  --data default_project_visibility=private \
  --data default_group_visibility=private \
  --data 'restricted_visibility_levels[]=public' >/dev/null
echo "settings applied"

# New projects: nobody pushes to the default branch directly, Maintainers merge. (Best effort: schema differs by version.)
jq -n '{default_branch_protection_defaults:{allowed_to_push:[{access_level:0}],allowed_to_merge:[{access_level:40}],allow_force_push:false,developer_can_initial_push:true}}' \
  | api PUT /application/settings -H 'Content-Type: application/json' -d @- >/dev/null \
  || echo "WARN: could not set default branch protection defaults; set it in Admin > Settings > Repository"

# ---- 2. Groups -----------------------------------------------------------------------
mkgroup() { # name [parent_id]
  local parent=${2:-} full
  full=$([[ -n $parent ]] && echo "company/$1" || echo "$1")
  local id; id=$(api GET "/groups/$(enc "$full")" 2>/dev/null | jq -r '.id // empty' || true)
  if [[ -n $id ]]; then echo "$id"; return 0; fi
  api POST /groups --data "name=$1" --data "path=$1" --data visibility=private ${parent:+--data "parent_id=$parent"} | jq -r .id
}
COMPANY=$(mkgroup company)
WEB=$(mkgroup team-web "$COMPANY")
MOBILE=$(mkgroup team-mobile "$COMPANY")
echo "groups: company=$COMPANY team-web=$WEB team-mobile=$MOBILE"

# ---- 3. Users (random passwords written to $OUT/users.txt) ---------------------------------
mkuser() { # username  "Full Name"
  local u=$1 name=$2 id pw
  id=$(api GET "/users?username=$u" | jq -r '.[0].id // empty')
  if [[ -z $id ]]; then
    pw=$(randpw)
    id=$(api POST /users --data-urlencode "username=$u" --data-urlencode "name=$name" \
          --data-urlencode "email=$u@company.internal" --data-urlencode "password=$pw" \
          --data skip_confirmation=true | jq -r .id)
    echo "$u $pw" >> "$OUT/users.txt"
  fi
  echo "$id"
}
ALICE=$(mkuser alice-owner      "Alice Owner")
BOB=$(mkuser   bob-maintainer   "Bob Maintainer")
CAROL=$(mkuser carol-developer  "Carol Developer")
DAVE=$(mkuser  dave-reporter    "Dave Reporter")

# ---- 4. Roles: 10 Guest | 20 Reporter | 30 Developer | 40 Maintainer | 50 Owner ----------------
addmember() { # group_id user_id level
  api POST "/groups/$1/members" --data "user_id=$2" --data "access_level=$3" >/dev/null 2>&1 \
    || api PUT "/groups/$1/members/$2" --data "access_level=$3" >/dev/null
}
addmember "$COMPANY" "$ALICE" 50   # Owner on the top-level group -> inherited by both subgroups
addmember "$WEB"     "$BOB"   40   # Maintainer, team-web only
addmember "$WEB"     "$CAROL" 30   # Developer, both teams
addmember "$MOBILE"  "$CAROL" 30
addmember "$MOBILE"  "$DAVE"  20   # Reporter, team-mobile only (cannot even see team-web)
echo "roles assigned"

# Optional: register a developer's SSH PUBLIC key, e.g.  CAROL_SSH_PUBKEY=~/carol.pub ./provision.sh
if [[ -n ${CAROL_SSH_PUBKEY:-} && -f $CAROL_SSH_PUBKEY ]]; then
  api POST "/users/$CAROL/keys" --data-urlencode "title=carol laptop" --data-urlencode "key=$(cat "$CAROL_SSH_PUBKEY")" >/dev/null
fi
# HTTPS clone needs a token (password git auth does not work with 2FA enforced).
api POST "/users/$CAROL/impersonation_tokens" --data name=carol-https-clone \
  --data 'scopes[]=read_repository' --data 'scopes[]=write_repository' \
  --data "expires_at=$(date -u -d '+30 days' +%F)" | jq -r .token > "$OUT/carol-https-token"

# ---- 5. Projects -------------------------------------------------------------------------
mkproject() { # name namespace_id
  local full; full=$(api GET "/groups/$2" | jq -r .full_path)/$1
  local id; id=$(api GET "/projects/$(enc "$full")" 2>/dev/null | jq -r '.id // empty' || true)
  if [[ -n $id ]]; then echo "$id"; return 0; fi
  api POST /projects --data "name=$1" --data "namespace_id=$2" --data visibility=private \
    --data initialize_with_readme=true | jq -r .id
}
WEBPROJ=$(mkproject web-sample "$WEB")
MOBPROJ=$(mkproject mobile-sample "$MOBILE")

# Commit the sample app + .gitlab-ci.yml BEFORE protecting main (afterwards nobody may push to it).
if ! api GET "/projects/$WEBPROJ/repository/files/.gitlab-ci.yml?ref=main" >/dev/null 2>&1; then
  SRC="$HERE/../sample-project"
  actions=$(cd "$SRC" && find . -type f | sed 's|^\./||' | while read -r f; do
    jq -n --arg p "$f" --rawfile c "$SRC/$f" '{action:"create",file_path:$p,content:$c}'; done | jq -s .)
  jq -n --argjson a "$actions" '{branch:"main",commit_message:"Add sample app and CI pipeline",actions:$a}' \
    | api POST "/projects/$WEBPROJ/repository/commits" -H 'Content-Type: application/json' -d @- >/dev/null
fi

# ---- 6. Protect main: no direct push (0), merge only via MR by Maintainers (40) --------------------
for p in "$WEBPROJ" "$MOBPROJ"; do
  api DELETE "/projects/$p/protected_branches/main" >/dev/null 2>&1 || true
  api POST "/projects/$p/protected_branches" --data name=main \
    --data push_access_level=0 --data merge_access_level=40 --data allow_force_push=false >/dev/null
done
echo "main protected on both projects"

# ---- 7. Masked + protected CI/CD variable (random value, never printed) ---------------------------
api POST "/projects/$WEBPROJ/variables" --data key=DEMO_API_TOKEN --data "value=$(openssl rand -hex 16)" \
  --data masked=true --data protected=true >/dev/null 2>&1 || echo "variable already exists"

# ---- 8. Group runner: create the runner on the server side, keep only its token ---------------------
if [[ ! -f $OUT/runner-token ]]; then
  api POST /user/runners --data runner_type=group_type --data "group_id=$COMPANY" \
    --data description=docker-runner-private --data tag_list=docker,private --data run_untagged=true \
    | jq -r .token > "$OUT/runner-token"
fi

# ---- 9. Revoke the temporary admin token ------------------------------------------------------------
[[ $CREATED_TOKEN == 1 ]] && api DELETE /personal_access_tokens/self >/dev/null && echo "temporary token revoked"

cat <<EOF

Done. Secrets are in $OUT (users.txt, carol-https-token, runner-token).
Users must enrol 2FA at first login (enforced). Next: runner/install-runner.sh
EOF
