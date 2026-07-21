#!/usr/bin/env bash
set -euo pipefail

# Run from repository root by default.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v oc >/dev/null 2>&1; then
  echo "Error: 'oc' no esta instalado en este entorno."
  echo "Instala OpenShift CLI o ejecuta este script en Cloud IDE/lab."
  exit 1
fi

if ! oc whoami >/dev/null 2>&1; then
  echo "Error: no hay sesion activa en OpenShift (kubeconfig/login faltante)."
  echo "Haz login primero, por ejemplo:"
  echo "  oc login --token=<TOKEN> --server=<API_URL>"
  echo "Luego selecciona tu proyecto:"
  echo "  oc project <NOMBRE_DEL_PROYECTO>"
  exit 1
fi

if ! command -v tkn >/dev/null 2>&1; then
  echo "Warning: 'tkn' no esta instalado. Se usaran comandos oc para logs."
fi

echo "Proyecto actual: $(oc project -q 2>/dev/null || echo 'desconocido')"

echo
printf '%s\n' "==> Aplicando tareas y pipeline"
oc apply -f .tekton/tasks.yaml -f .tekton/pipeline.yaml

echo
printf '%s\n' "==> Lanzando PipelineRun"
oc create -f .tekton/run.yaml

echo
printf '%s\n' "==> Esperando a que aparezca el PipelineRun"
for i in {1..30}; do
  RUN_NAME="$(oc get pipelineruns --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${RUN_NAME}" ]]; then
    break
  fi
  sleep 2
done

if [[ -z "${RUN_NAME:-}" ]]; then
  echo "Error: no se pudo obtener el nombre del PipelineRun."
  exit 1
fi

echo "PipelineRun: ${RUN_NAME}"

echo
printf '%s\n' "==> Logs del PipelineRun"
if command -v tkn >/dev/null 2>&1; then
  tkn pipelinerun logs "$RUN_NAME" -f || true
else
  # Fallback using oc: print all TaskRun pod logs.
  TASKRUNS="$(oc get taskrun -l tekton.dev/pipelineRun=${RUN_NAME} -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' || true)"
  if [[ -z "$TASKRUNS" ]]; then
    echo "No se encontraron TaskRuns aun."
  else
    while IFS= read -r tr; do
      [[ -z "$tr" ]] && continue
      pod="$(oc get pod -l tekton.dev/taskRun=${tr} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
      if [[ -n "$pod" ]]; then
        echo "--- Logs de $pod ---"
        oc logs "$pod" --all-containers=true || true
      fi
    done <<< "$TASKRUNS"
  fi
fi

echo
printf '%s\n' "==> Estado final del PipelineRun"
oc get pipelinerun "$RUN_NAME"

echo
printf '%s\n' "==> Verificando recursos"
oc get deployment tax-calculator || true
oc get service tax-calculator || true
oc get route tax-calculator || true

echo
ROUTE_HOST="$(oc get route tax-calculator -o jsonpath='{.spec.host}' 2>/dev/null || true)"
if [[ -n "$ROUTE_HOST" ]]; then
  echo "Application URL:"
  echo "https://${ROUTE_HOST}"
  echo
  echo "Abre esa URL y toma la captura como: 10-final-output"
else
  echo "No se encontro route tax-calculator aun. Revisa los logs de build-and-deploy."
  exit 1
fi
