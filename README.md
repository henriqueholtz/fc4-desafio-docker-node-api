# flags-api — Do Dev à Produção

## Sobre a entrega

API REST de feature flags (Node.js 22 + TypeScript + PostgreSQL) containerizada em dois ambientes a partir de um único `Dockerfile` multi-stage (`dev`, `build`, `prod-deps`, `production`). O ambiente de desenvolvimento (`compose.yaml`) prioriza produtividade: `docker compose watch` sincroniza `src/` sem rebuild, Adminer opcional via profile `tools` e dados descartáveis em volume nomeado. O de produção (`compose.prod.yaml`) consome a imagem publicada no Docker Hub, com restart policy, limites de CPU/memória, healthchecks e container hardening (`read_only`, `cap_drop: ALL`, `no-new-privileges`).

As migrações rodam automaticamente: no dev, via `command` (`npm run db:migrate && npm run dev`); em produção, via serviço one-shot `migrate` (`node dist/db/migrate.js`) do qual o `app` depende com `service_completed_successfully`. O código da aplicação não foi alterado.

## Imagem no Docker Hub

- Repositório: https://hub.docker.com/r/henriqueholtz/fc4-desafio-docker-node-api
- Pull: `docker pull henriqueholtz/fc4-desafio-docker-node-api:1.0.0`
- Digest do manifest (1.0.0 = latest): `sha256:9e614c70b18c6ff31c5eb1c31b4eccb88ea330f7cf31314ba2f90bde09c2683d`

| Imagem | Tamanho |
|---|---|
| dev (`--target dev`) | ~211 MB |
| production (linux/amd64) | 171 MB (`docker image ls` após `docker pull --platform linux/amd64`) |

## Decisões técnicas

**Base de produção: `node:22.23.4-alpine3.24`.** Alpine (musl) mantém a imagem em ~170 MB, traz usuário `node` não-root e é a base oficial com versão fixada. Alternativas consideradas: `node:22-slim` (Debian, ~230 MB, mais pacotes e mais CVEs de SO) e distroless (`gcr.io/distroless/nodejs22`, menor superfície, porém sem shell, dificultando debug em um ambiente que será submetido a pentest e sem tag semver de Node tão granular). Como as dependências (`express`, `pg`, `dotenv`) são JS puro, musl não é problema. No estágio final, npm, npx, corepack e yarn são removidos: não são necessários em runtime e reduzem superfície de ataque e CVEs.

**Cache de build.** `package.json` e `package-lock.json` são copiados antes do código, de modo que a camada de `npm ci` só é invalidada quando as dependências mudam. Todo `npm ci` usa `RUN --mount=type=cache,target=/root/.npm`, reaproveitando o cache de download do npm entre builds. Um estágio `prod-deps` isola `npm ci --omit=dev`, e `production` copia apenas `node_modules` de produção e `dist/`.

**Dependências transitivas vulneráveis.** O `package-lock.json` (que não pode ser alterado) fixa `proxy-addr@2.0.7` (CRITICAL, CVE-2026-90711), `body-parser@2.3.0` (HIGH, CVE-2026-111181) e `qs@6.15.3` (MEDIUM, CVE-2026-82562 e CVE-2026-82417). No estágio `prod-deps`, após o `npm ci --omit=dev`, um `npm install --no-save` atualiza apenas essas três para as versões corrigidas (`2.0.8`, `2.4.0`, `6.16.0`) dentro do `node_modules` da imagem, sem tocar nos arquivos do repositório. As versões são compatíveis com os ranges exigidos pelo `express@5.2.1`.

## Como rodar (desenvolvimento)

```bash
cp .env.example .env
docker compose up --build            # API em http://localhost:3000
curl -i http://localhost:3000/flags  # 200

docker compose up --watch            # (ou: docker compose watch) sync de src/, rebuild em package.json
docker compose --profile tools up -d # Adminer em http://localhost:8081 (servidor: db)
docker compose down -v               # remove containers e dados
```

## Como rodar (produção)

```bash
cp .env.example .env
docker compose -f compose.prod.yaml up -d
docker compose -f compose.prod.yaml ps    # app e db healthy
curl -i http://localhost:3000/flags        # 200
docker compose -f compose.prod.yaml down   # (-v para apagar dados)
```

Publicação da imagem (multi-arch, SBOM e provenance):

```bash
docker login
docker buildx create --name multiarch --driver docker-container --use   # uma vez
docker buildx build --target production --platform linux/amd64,linux/arm64 \
  --sbom=true --provenance=mode=max \
  --build-arg VERSION=1.0.0 \
  -t henriqueholtz/fc4-desafio-docker-node-api:1.0.0 \
  -t henriqueholtz/fc4-desafio-docker-node-api:latest --push .
```

## Segurança e supply chain

```bash
IMG=henriqueholtz/fc4-desafio-docker-node-api:1.0.0
docker image inspect $IMG --format 'User={{.Config.User}}'
docker image inspect $IMG --format '{{json .Config.Labels}}'
docker image inspect $IMG --format '{{json .Config.Healthcheck}}'
docker buildx imagetools inspect $IMG --format '{{json .SBOM}}'
docker buildx imagetools inspect $IMG --format '{{json .Provenance}}'
docker scout cves --only-severity critical --only-fixed $IMG
```

Relatório completo: [reports/scout-cves.txt](reports/scout-cves.txt).

**Resumo do Scout:** 109 pacotes indexados; 0 CRITICAL, 0 HIGH, 0 MEDIUM, 0 LOW e 1 UNSPECIFIED. `--only-severity critical --only-fixed` retorna "No vulnerable package detected"..

**CVEs remanescentes (HIGH / CRITICAL sem correção):** nenhuma HIGH nem CRITICAL. Resta apenas CVE-2026-107891 em `musl 1.2.6-r3` (severidade UNSPECIFIED), cuja correção (`1.2.6-r6`) ainda não foi publicada nos repositórios do Alpine 3.24 (um `apk upgrade` na build não a traz). Mitigação: a imagem usa base fixada e deve ser reconstruída quando o Alpine publicar o pacote corrigido..

## Validação

| Critério | Comando |
|---|---|
| Estágios dev/build/production | `grep -E '^FROM .* AS (dev\|build\|production)' Dockerfile` |
| Sem tag `latest`/sem tag nas bases | `grep -E '^\s*(FROM\|image:)' Dockerfile compose*.yaml` |
| `.dockerignore` | `cat .dockerignore` |
| Cache mount | `grep -n 'mount=type=cache' Dockerfile` |
| Builds locais | `docker build --target dev .` e `docker build --target production .` |
| Dev sobe e `/flags` = 200 | `cp .env.example .env && docker compose up -d --build && curl -i localhost:3000/flags` |
| db healthcheck + `service_healthy` | `docker compose config \| grep -B2 -A2 service_healthy` |
| Watch | `docker compose up --watch`; editar `src/` (sync) e `package.json` (rebuild) |
| Adminer | `docker compose --profile tools up -d` → http://localhost:8081 |
| Usuário não-root (dev) | `docker compose exec app id -u` (1000) |
| `.env` ignorado, `.env.example` versionado | `git check-ignore .env && git ls-files .env.example` |
| Multi-arch | `docker buildx imagetools inspect $IMG` (amd64 e arm64) |
| SBOM/provenance | `docker buildx imagetools inspect $IMG --format '{{json .SBOM}}'` / `'{{json .Provenance}}'` |
| Mesmo digest 1.0.0 e latest | `docker buildx imagetools inspect $IMG --format '{{.Manifest.Digest}}'` (repetir com `:latest`) |
| Tamanho ≤ 350 MB | `docker pull --platform linux/amd64 $IMG && docker image ls henriqueholtz/fc4-desafio-docker-node-api` |
| User/Healthcheck/labels | comandos da seção Segurança |
| Healthy em produção | `docker compose -f compose.prod.yaml ps` |
| Stop < 10 s | `time docker stop flags-api-prod-app-1` |
| Scout sem CRITICAL corrigível | `docker scout cves --only-severity critical --only-fixed $IMG` |
| prod sem build, restart, limites, sem bind mount | `docker compose -f compose.prod.yaml config` |
| Código da aplicação intacto | `git diff --stat c956e42 -- src package.json package-lock.json tsconfig.json` |
