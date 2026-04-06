#!/bin/bash

# =============================================================================
# entrypoint.sh
#
# Script principal da GitHub Action kubernetes-eks.
# Responsável por:
#   1. Validar as variáveis de ambiente obrigatórias e opcionais.
#   2. Configurar as credenciais AWS e o kubeconfig.
#   3. Descobrir e classificar os manifests YAML por tipo de recurso.
#   4. Aplicar os manifests no cluster EKS respeitando a ordem de dependência.
#   5. Monitorar o rollout dos recursos que possuem Pods, detectando falhas
#      rapidamente (CrashLoopBackOff) e permitindo cancelamento pelo GitHub Actions.
# =============================================================================

#set -e
#
echo ""
echo "Checking ENVs..."

# -----------------------------------------------------------------------------
# Validação das variáveis de ambiente obrigatórias.
# O script falha imediatamente se qualquer uma delas estiver ausente,
# pois sem elas não é possível autenticar na AWS nem no cluster.
# -----------------------------------------------------------------------------
if [ -z "$AWS_ACCESS_KEY_ID" ]; then
  echo 'Env AWS_ACCESS_KEY_ID is empty! Please, fulfil it with your aws access key...'
  exit 1
elif [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
  echo 'Env AWS_SECRET_ACCESS_KEY is empty! Please, fulfil  with your aws access secret...'
  exit 1
elif [ -z "$KUBECONFIG" ]; then
  echo 'Env KUBECONFIG is empty! Please, fulfil it with your kubeconfig in base64...'
  exit 1
elif [ -z "$KUBE_YAML" ]; then
  # Aceita FILES_PATH como alternativa a KUBE_YAML para apontar um diretório inteiro.
  if [ -z "$FILES_PATH" ]; then
    echo "Envs KUBE_YAML or FILES_PATH is empty or file doesn't exist! Please, fulfil it with full path where your file is..."
    exit 1
  else
    echo 'Envs filled!'
    echo ""
  fi
fi

# -----------------------------------------------------------------------------
# Valores padrão para variáveis opcionais.
# Cada bloco aplica o default apenas quando a variável não foi fornecida
# ou tem um valor inválido, garantindo comportamento previsível.
# -----------------------------------------------------------------------------

# Perfil AWS a ser usado no ~/.aws/credentials (default: "default").
if [ -z "$AWS_PROFILE_NAME" ]; then
  AWS_PROFILE_NAME='default'
  echo 'Env AWS_PROFILE_NAME is empty! Using default.'
fi

# ENVSUBST=true faz o script substituir variáveis de ambiente nos YAMLs antes de aplicá-los.
if [ "$ENVSUBST" != "true" ] && [ "$SUBPATH" != "ENVSUBST" ]; then
  ENVSUBST=false
  echo 'Env ENVSUBST is empty! Using default=false.'
fi

# SUBPATH=true permite que o script busque YAMLs recursivamente em subdiretórios.
if [ "$SUBPATH" != "true" ] && [ "$SUBPATH" != "false" ]; then
  SUBPATH=false
  echo 'Env SUBPATH is empty or wrong value! Using default=false.'
fi

# CONTINUE_IF_FAIL=true faz o script continuar mesmo que um apply/rollout falhe.
if [ "$CONTINUE_IF_FAIL" != "true" ] && [ "$CONTINUE_IF_FAIL" != "false" ]; then
  CONTINUE_IF_FAIL=false
  echo 'Env CONTINUE_IF_FAIL is empty! Using default=false.'
fi

# KUBE_ROLLOUT=true habilita o acompanhamento do rollout após cada apply.
if [ "$KUBE_ROLLOUT" != "true" ] && [ "$KUBE_ROLLOUT" != "false" ]; then
  KUBE_ROLLOUT=true
  echo 'Env KUBE_ROLLOUT is empty! Using default=true.'
fi

# KUBE_ROLLOUT_TIMEOUT define quanto tempo aguardar o rollout antes de falhar (default: 20m).
if [ -z "$KUBE_ROLLOUT_TIMEOUT" ]; then
  KUBE_ROLLOUT_TIMEOUT='20m'
  echo 'Env KUBE_ROLLOUT_TIMEOUT is empty! Using default 20m.'
fi

# Valida o formato do timeout: deve ser um número seguido de s, m ou h (ex: 60s, 5m, 1h).
if ! [[ $KUBE_ROLLOUT_TIMEOUT =~ ^[0-9]+[smh]$ ]]; then
    echo "Erro: O KUBE_ROLLOUT_TIMEOUT must be in time format. (i.e.: 60s, 5m, 1h)."
    exit 1
fi

echo ""

# -----------------------------------------------------------------------------
# Configuração das credenciais AWS e do kubeconfig.
# Os valores chegam como variáveis de ambiente e são gravados nos paths
# esperados pelo AWS CLI e pelo kubectl, respectivamente.
# -----------------------------------------------------------------------------
mkdir -p ~/.aws
mkdir -p ~/.kube

AWS_CREDENTIALS_PATH='~/.aws/credentials'
KUBECONFIG_PATH='~/.kube/config'

# Grava o arquivo de credenciais AWS com o perfil configurado.
echo "[$AWS_PROFILE_NAME]" > $(eval echo $AWS_CREDENTIALS_PATH)
echo "aws_access_key_id = $AWS_ACCESS_KEY_ID" >> $(eval echo $AWS_CREDENTIALS_PATH)
echo "aws_secret_access_key = $AWS_SECRET_ACCESS_KEY" >> $(eval echo $AWS_CREDENTIALS_PATH)

# Decodifica o kubeconfig (enviado em base64) e salva no path padrão do kubectl.
echo "$KUBECONFIG" |base64 -d > $(eval echo $KUBECONFIG_PATH)

# Remove a variável KUBECONFIG do ambiente para evitar conflito com o arquivo gravado acima.
unset KUBECONFIG


###================================
# FUNÇÕES
###================================

# -----------------------------------------------------------------------------
# check_directories_and_files
#
# Valida que cada diretório informado existe e contém pelo menos um arquivo
# .yaml ou .yml. Respeita a flag SUBPATH para busca recursiva ou não.
# -----------------------------------------------------------------------------
check_directories_and_files() {
  local dirs=("$@")
  for dir in "${dirs[@]}"; do
    if [ -d "$dir" ]; then
      # Verifica se há pelo menos um arquivo .yaml ou .yml no diretório ou subdiretório
      if [ "$SUBPATH" == "true" ]; then
        if ! find "$dir" -type f \( -name "*.yaml" -o -name "*.yml" \) | grep -q .; then
          echo "No files .yaml or .yml found in dir: $dir"
          echo "No files .yaml or .yml found in dir: $dir" >> $GITHUB_STEP_SUMMARY
          exit 1
        fi
      else
        if ! find "$dir" -maxdepth 1 -type f \( -name "*.yaml" -o -name "*.yml" \) | grep -q .; then
          echo "No files .yaml or .yml found in dir: $dir"
          echo "No files .yaml or .yml found in dir: $dir" >> $GITHUB_STEP_SUMMARY
          exit 1
        fi
      fi
    else
      echo "Path $dir doen't exist."
      echo "Path $dir doen't exist." >> $GITHUB_STEP_SUMMARY
      exit 1
    fi
  done
}

# -----------------------------------------------------------------------------
# check_files_exist
#
# Verifica que cada arquivo informado existe no filesystem e chama
# check_yaml_files para validar a extensão.
# -----------------------------------------------------------------------------
check_files_exist() {
  local files=("$@")
  for file in "${files[@]}"; do
    if [ -e "$file" ]; then
      check_yaml_files $file
    else
      echo "File: $file not found, Please, check if file path is set correctly."
      echo "File: $file not found, Please, check if file path is set correctly." >> $GITHUB_STEP_SUMMARY
      exit 1
    fi
  done
}

# -----------------------------------------------------------------------------
# check_yaml_files
#
# Garante que o arquivo tem extensão .yaml ou .yml. Outras extensões são
# rejeitadas para evitar que arquivos não-Kubernetes sejam aplicados.
# -----------------------------------------------------------------------------
check_yaml_files() {
  local files=("$@")
  for file in "${files[@]}"; do
    if [[ ! "$file" =~ \.ya?ml$ ]]; then
      echo "File: $file with extension not allowed. Please declare \"*.yaml\" or \"*.yml\""
      echo "File: $file with extension not allowed. Please declare \"*.yaml\" or \"*.yml\"" >> $GITHUB_STEP_SUMMARY
      exit 1
    fi
  done
}

# -----------------------------------------------------------------------------
# createJsonFiles
#
# Lê um arquivo YAML, extrai o campo .kind e o adiciona ao FILES_JSON,
# que é um objeto indexado por tipo de recurso (ex: Deployment, Service...).
#
# Caso o arquivo contenha múltiplos recursos separados por "---", usa csplit
# para dividi-lo em arquivos individuais e processa cada um recursivamente.
#
# Parâmetros:
#   $1 — caminho do arquivo YAML
#   $2 — nome original do arquivo (usado no resumo do GitHub Actions)
# -----------------------------------------------------------------------------
createJsonFiles () {
  #Local do arquivo a ser aplicado
  local file="$1"
  #Env que será usada para realizar o print na página do Actions
  local name_file="$2"
  local kind="$(yq eval '.kind' $file)"

  #Folder que será usado para amarzernar os arquivos splitados
  local folder_split='csplit'
  local tmp_dir='tmp_dir'

  # Remove o separador "---" da primeira linha, caso exista, pois o csplit
  # usa "---" como delimitador e uma linha inicial causaria um arquivo vazio.
  if [ "$(head -1 $file)" == "---" ]; then
    sed -i '1d' $file
  fi

  # Se o arquivo contém múltiplos recursos (separados por "---"), divide-o
  # em arquivos individuais usando csplit e processa cada um recursivamente.
  if [ $(grep "^---$" "$file" | wc -l) -ne 0 ]; then
    #cria o diretório csplit
    mkdir -p $folder_split
    mkdir -p $tmp_dir
    #Não funciona no MacOS
    csplit --prefix="$(uuidgen | cut -c1-4)_artifact_" --suffix-format="%02d.yaml" "$file" "/---/" "{*}" > /dev/null 2>&1
    #Move os novos arquivos criados
    cp *_artifact_* $folder_split
    #Esse tmp existe para o find procurar em um lugar único, se não, ele sempre lista tudo do diretório atual
    cp *_artifact_* $tmp_dir
    #Remove o arquivo com ---
    rm $file
    #Remove arquivos que já foram copiados para não dar duplicidade
    rm -rf *_artifact_*

    #Lista dos novos arquivos
    local NEW_FILES_YAML=($(find $tmp_dir -type f \( -name "*.yml" -o -name "*.yaml" \) | paste -sd ' ' -))

    #Remove arquivos locais para não haver repetição na próxima iteração
    rm -rf $tmp_dir

    # Chama recursivamente para cada arquivo gerado, substituindo o path
    # tmp_dir pelo path definitivo csplit.
    for j in ${NEW_FILES_YAML[@]}; do
      createJsonFiles "$(echo -n $j | sed 's/tmp_dir/csplit/')" $file
    done

  else
    # Arquivo simples (recurso único): registra no FILES_JSON sob a chave do kind.
    if [ -z "$name_file" ]; then
      local name_file="$file"
    fi

    #Adiciona no Json o arquivo
    FILES_JSON="$(echo -n $FILES_JSON | jq -cr "(.$kind | .files) += [{"file":\"$file\","print":\"$name_file\"}]")"
  fi
}

# -----------------------------------------------------------------------------
# envSubstitution
#
# Substitui no arquivo YAML todas as ocorrências de variáveis de ambiente
# no formato $NOME_DA_VAR pelo valor atual. Útil para injetar valores
# dinâmicos (ex: tag da imagem) em tempo de deploy.
#
# Parâmetros:
#   $1 — caminho do arquivo YAML a ser modificado in-place
# -----------------------------------------------------------------------------
envSubstitution () {
  local file="$1"

  echo "============================="
  echo "Change envs in file: $file"

  for ENV_VAR in $(env |cut -f 1 -d =); do
    local VAR_KEY=$ENV_VAR
    local VAR_VALUE=$(eval echo \$$ENV_VAR | sed -e 's/\//\\&/g;s/\&/\\&/g;')
    sed -i "s/\$$VAR_KEY/$VAR_VALUE/g" $file
  done
}

# -----------------------------------------------------------------------------
# run_rollout_status
#
# Substitui a chamada direta de "kubectl rollout status" para resolver dois
# problemas:
#
#   1. CANCELAMENTO PELO GITHUB ACTIONS:
#      O kubectl roda em background. Um trap em SIGTERM/SIGINT mata o processo
#      e encerra o script quando o usuário cancela o workflow pela UI.
#
#   2. DETECÇÃO RÁPIDA DE CRASHLOOPBACKOFF:
#      Enquanto o rollout está pendente, um loop verifica a cada 5 segundos
#      se algum pod do recurso entrou em estado de falha. Se detectado, o
#      kubectl em background é morto e a função retorna erro imediatamente,
#      sem aguardar o timeout completo.
#
# Parâmetros:
#   $1 — caminho do arquivo YAML do recurso
#   $2 — kind do recurso (ex: "Deployment")
#   $3 — nome do recurso (metadata.name)
# -----------------------------------------------------------------------------
run_rollout_status () {
  local file="$1"
  local resource_kind="$2"   # e.g. "Deployment"
  local resource_name="$3"

  # Converte o kind para lowercase para uso nos comandos kubectl (ex: "deployment").
  local kind_lower
  kind_lower=$(echo "$resource_kind" | tr '[:upper:]' '[:lower:]')

  # Lê o namespace do manifest; usa "default" caso não esteja definido.
  local namespace
  namespace=$(yq eval '.metadata.namespace // "default"' "$file")

  # Inicia o kubectl rollout status em background para que sinais externos
  # possam interrompê-lo sem travar o script.
  kubectl rollout status --filename "$file" --timeout="$KUBE_ROLLOUT_TIMEOUT" &
  local ROLLOUT_PID=$!

  # Configura trap para SIGTERM e SIGINT (enviados pelo GitHub Actions ao cancelar
  # o workflow). Ao receber o sinal, mata o kubectl em background e encerra o script.
  trap "echo 'Pipeline cancelled. Stopping rollout...'; kill $ROLLOUT_PID 2>/dev/null; wait $ROLLOUT_PID 2>/dev/null; exit 130" SIGTERM SIGINT

  # Resolve o label selector dos pods associados ao recurso.
  # Necessário para filtrar apenas os pods deste deploy no loop de monitoramento.
  # Pods são ignorados aqui pois eles mesmos são monitorados diretamente abaixo.
  local selector=""
  if [ "$kind_lower" != "pod" ]; then
    sleep 2  # Aguarda brevemente para o recurso estar visível na API do Kubernetes.
    selector=$(kubectl get "$kind_lower" "$resource_name" -n "$namespace" \
      -o jsonpath='{.spec.selector.matchLabels}' 2>/dev/null \
      | jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")' 2>/dev/null)
  fi

  # Loop de monitoramento: verifica a cada 5 segundos enquanto o rollout está rodando.
  # Estados de falha monitorados:
  #   - CrashLoopBackOff: container falha repetidamente ao iniciar.
  #   - OOMKilled: container encerrado por falta de memória.
  #   - ImagePullBackOff / ErrImagePull: imagem Docker não pode ser baixada.
  while kill -0 "$ROLLOUT_PID" 2>/dev/null; do
    local crash_info=""
    if [ -n "$selector" ]; then
      # Para Deployments, DaemonSets e ReplicaSets: busca pods pelo selector do recurso.
      crash_info=$(kubectl get pods -n "$namespace" -l "$selector" --no-headers 2>/dev/null \
        | grep -E "(CrashLoopBackOff|OOMKilled|ImagePullBackOff|ErrImagePull)" | head -3)
    elif [ "$kind_lower" == "pod" ]; then
      # Para Pods standalone: verifica diretamente o status do pod pelo nome.
      crash_info=$(kubectl get pod "$resource_name" -n "$namespace" --no-headers 2>/dev/null \
        | grep -E "(CrashLoopBackOff|OOMKilled|ImagePullBackOff|ErrImagePull)" | head -1)
    fi

    # Se algum pod falhou, interrompe o rollout imediatamente (fail fast).
    if [ -n "$crash_info" ]; then
      echo ""
      echo "ERROR: Pod(s) detected in failed state — failing fast:"
      echo "$crash_info"
      kill "$ROLLOUT_PID" 2>/dev/null
      wait "$ROLLOUT_PID" 2>/dev/null
      trap - SIGTERM SIGINT
      return 1
    fi
    sleep 5
  done

  # Aguarda o kubectl terminar e captura o código de saída (0 = sucesso, !0 = falha/timeout).
  wait "$ROLLOUT_PID"
  local rollout_exit=$?

  # Remove o trap após o rollout concluir normalmente para não afetar outros comandos.
  trap - SIGTERM SIGINT
  return $rollout_exit
}

# -----------------------------------------------------------------------------
# artifactType
#
# Itera sobre todos os arquivos de um determinado tipo de recurso Kubernetes
# (ex: todos os Deployments) e chama applyFile para cada um.
#
# Parâmetros:
#   $1 — tipo do recurso (ex: "Deployment", "Service")
#   $2 — true/false: se deve acompanhar o rollout após o apply
# -----------------------------------------------------------------------------
artifactType () {
  local type="$1"
  local kube_rollout="$2"

  echo "============================="
  echo "Type: $type"
  echo -n "| $type | " >> $GITHUB_STEP_SUMMARY

  #Usado para formatar o output na página do github Action
  tmp_count=0
  for json_file in $(echo -n "$FILES_JSON" | jq -cr ".$type.files[]"); do
    local file="$(echo -n $json_file | jq -cr '.file')"
    local print_name="$(echo -n $json_file | jq -cr '.print')"

    # Substitui variáveis de ambiente no YAML antes de aplicar, se habilitado.
    if [ "$ENVSUBST" = "true" ]; then
      envSubstitution $file
    fi

    #Apply file
    applyFile $file $print_name $tmp_count $type $kube_rollout
    #Incrementa o Count
    tmp_count=$((tmp_count + 1))
  done
}

# -----------------------------------------------------------------------------
# applyFile
#
# Aplica um único manifest YAML no cluster e, opcionalmente, acompanha o
# rollout do recurso. Registra o resultado no resumo do GitHub Actions.
#
# Lógica do rollout:
#   - "unchanged": o manifest não mudou, mas um rollout restart é forçado
#     para garantir que a imagem/configuração mais recente seja usada.
#   - "configured" / "created": o recurso foi atualizado ou criado;
#     o Kubernetes já iniciará o rollout automaticamente, basta monitorar.
#
# Parâmetros:
#   $1 — caminho do arquivo YAML
#   $2 — nome original do arquivo (para exibição no resumo)
#   $3 — índice do arquivo dentro do tipo (para formatação da tabela)
#   $4 — tipo do recurso (ex: "Deployment")
#   $5 — true/false: se deve monitorar o rollout
# -----------------------------------------------------------------------------
applyFile () {
  local file="$1"
  local print_name="$2"
  local tmp_count="$3"
  local type="$4"
  local kube_rollout="$5"

  # Deixa a célula de tipo em branco para arquivos subsequentes do mesmo tipo,
  # evitando repetição na tabela de resumo do GitHub Actions.
  if [ $tmp_count -gt 0 ]; then
    echo -n "| | " >> $GITHUB_STEP_SUMMARY
  fi

  # Extrai o nome do recurso do manifest para exibição no resumo.
  local resource_name=$(echo -n "$(yq eval '.metadata.name' $file)")
  echo -n "$resource_name" >> $GITHUB_STEP_SUMMARY

  # Aplica o manifest no cluster e captura a saída para determinar o estado
  # (created / configured / unchanged) e decidir o comportamento do rollout.
  echo "Applying file: $file"
  echo "Original file: $print_name"
  echo -n " | $print_name" >> $GITHUB_STEP_SUMMARY
  echo "-----------------------------"
  KUBE_APPLY=$(kubectl apply -f $file 2>&1)
  KUBE_EXIT_CODE=$?
  if [ $KUBE_EXIT_CODE -ne 0 ]; then
    echo "Erro ao aplicar o arquivo: $file"
    echo " | Failed :x: |" >> $GITHUB_STEP_SUMMARY
    echo "KUBE_EXIT_CODE: $KUBE_EXIT_CODE"
    echo "KUBECTL_OUTPUT: $KUBE_APPLY"
    # Interrompe o script se CONTINUE_IF_FAIL=false (comportamento padrão).
    if ! $CONTINUE_IF_FAIL; then
      exit 1
    fi
  else
    echo "Arquivo aplicado com sucesso: $file"
    echo " | Passed :white_check_mark: |" >> $GITHUB_STEP_SUMMARY
  fi

  # Acompanha o rollout apenas para recursos que gerenciam Pods
  # (Deployment, DaemonSet, ReplicaSet, Pod) e quando KUBE_ROLLOUT=true.
  if [ "$kube_rollout" == true ]; then
    echo "============================="
    echo ""
    echo "============================="

    # Registra o timestamp de início para calcular o tempo de execução do rollout.
    local kube_rollout_start_time=$(date +%s)

    if [ "$(echo $KUBE_APPLY |sed 's/.* //')" == "unchanged" ]; then
      # Recurso sem alteração no manifest: força um restart para que a imagem
      # ou configuração mais recente (ex: nova tag via ENVSUBST) seja aplicada.
      echo "Applying rollout:"
      kubectl rollout restart --filename $file
      echo ""
      echo "Checking rollout status:"
      run_rollout_status "$file" "$type" "$resource_name"
      local kube_rollout_status=$?
    elif ([ "$(echo $KUBE_APPLY |sed 's/.* //')" == "configured" ] || [ "$(echo $KUBE_APPLY |sed 's/.* //')" == "created" ]); then
      # Recurso atualizado ou criado: o Kubernetes já iniciou o rollout;
      # apenas monitora até a conclusão ou falha.
      echo "Checking rollout status:"
      run_rollout_status "$file" "$type" "$resource_name"
      local kube_rollout_status=$?
    fi

    # Registra o timestamp de fim e calcula o tempo total do rollout.
    local kube_rollout_end_time=$(date +%s)

    # Calcula o tempo total de execução em segundos
    local kube_rollout_execution_time=$((kube_rollout_end_time - kube_rollout_start_time))

    # Converte o tempo total em minutos e segundos
    local minutes=$((kube_rollout_execution_time / 60))
    local seconds=$((kube_rollout_execution_time % 60))

    # Verifica se o comando foi bem-sucedido
    if [ $kube_rollout_status -eq 0 ]; then
        echo "O rollout foi bem-sucedido."
        local kube_rollout_mark=true
    else
        echo "O rollout falhou ou atingiu o timeout."
        local kube_rollout_mark=false
    fi

    # Salva o resultado do rollout no array JSON para ser exibido na tabela
    # de resumo do GitHub Actions ao final do script.
    KUBE_ROLLOUT_JSON+=("{\"type\":\"$type\",\"file\":\"$print_name\",\"resource_name\":\"$resource_name\",\"time\":\"${minutes}m:${seconds}s\",\"status\":$kube_rollout_mark}")

    # Exibe o tempo total de execução no formato Xm:Xs
    echo "Tempo de execução: ${minutes}m:${seconds}s."
  fi

  echo "$KUBE_APPLY"
  echo "============================="
  echo ""
}

###===========================================================
# INÍCIO DA EXECUÇÃO
###===========================================================

# -----------------------------------------------------------------------------
# Preparação dos inputs.
# FILES_PATH e KUBE_YAML podem conter múltiplos valores separados por vírgula;
# aqui eles são convertidos em arrays bash para iteração.
# -----------------------------------------------------------------------------
IFS=',' read -r -a FT_FILES_PATH <<< "$FILES_PATH"
IFS=',' read -r -a FT_KUBE_YAML <<< "$KUBE_YAML"

# Array que acumula o resultado JSON de cada rollout para a tabela de resumo.
KUBE_ROLLOUT_JSON=()

# Flag global que indica se algum rollout falhou; usada ao final para
# decidir se o script deve sair com erro mesmo após processar todos os recursos.
KUBE_ROLLOUT_FAILED=false

# -----------------------------------------------------------------------------
# Validação dos paths e arquivos informados pelo usuário.
# -----------------------------------------------------------------------------

# Valida se os paths existem e contêm arquivos YAML.
if [ ${#FT_FILES_PATH[@]} -gt 0 ]; then
  check_directories_and_files ${FT_FILES_PATH[@]}
fi

# Valida se os arquivos individuais existem e possuem extensões válidas.
if [ ${#FT_KUBE_YAML[@]} -gt 0 ]; then
  check_files_exist ${FT_KUBE_YAML[@]}
fi

# Remove a barra final de cada diretório informado, caso exista,
# para evitar caminhos duplicados (ex: "k8s//" ao concatenar com "/arquivo.yaml").
for i in "${!FT_FILES_PATH[@]}"; do
  if [[ "${FT_FILES_PATH[$i]}" == */ ]]; then
    FT_FILES_PATH[$i]="${FT_FILES_PATH[$i]%/}"
  fi
done

# -----------------------------------------------------------------------------
# Descoberta dos arquivos YAML.
# Coleta todos os arquivos .yaml/.yml dos diretórios informados e os une
# com os arquivos individuais especificados em KUBE_YAML.
# -----------------------------------------------------------------------------
for j in "${!FT_FILES_PATH[@]}"; do
  #Lista de arquivos
  FILES_YAML+=($(find ${FT_FILES_PATH[$j]} -type f \( -name "*.yml" -o -name "*.yaml" \) | paste -sd ' ' -))
done

FILES_JSON='{}'

# Inclui os arquivos individuais de KUBE_YAML junto aos encontrados nos diretórios.
FILES_YAML+=("${FT_KUBE_YAML[@]}")

# -----------------------------------------------------------------------------
# Classificação dos arquivos por tipo de recurso Kubernetes (FILES_JSON).
# Cada arquivo é lido, seu .kind extraído e registrado em FILES_JSON, que
# serve como índice para a aplicação ordenada na próxima etapa.
# Se SUBPATH=false, arquivos em subdiretórios além do informado são ignorados.
# -----------------------------------------------------------------------------
for i in ${FILES_YAML[@]}; do

  if $SUBPATH; then
    # SUBPATH=true: inclui arquivos em qualquer nível de subdiretório.
    createJsonFiles $i
  else
    #Quantidade total de subpath no arquivo a ser aplicado
    qtd_path_file=$(echo "$i" | tr -cd '/' | wc -c | tr -d ' ')
    #Percorre cada arquivo para contar a quantidade de path
    for path in "${FT_FILES_PATH[@]}"; do
      #Retira o path informado pelo usuário do path total do arquivo
      file_no_path=$(echo "$i" | sed "s|^$path/||")
      #Verifica se o arquivo a ser aplicado tem em seu path um dos path (em caso de vetor) informado pelo usuário
      if [ "$i" != "$file_no_path" ];then
        qtd_subpath=$(echo "$file_no_path" | tr -cd '/' | wc -c | tr -d ' ')
      fi
    done
    # SUBPATH=false: ignora arquivos que estejam em sub-diretórios além do informado.
    if [ -n "$FILES_PATH" ]; then
      if [ $qtd_subpath -gt 0 ]; then
        echo "SUBPATH=false. Ignoring file: $i"
      else
        createJsonFiles $i
      fi
    else
      # KUBE_YAML foi informado diretamente (sem FILES_PATH): inclui o arquivo.
      createJsonFiles $i
    fi
  fi
done

echo ""

# Inicia a tabela de status de deploy no resumo do GitHub Actions.
echo "## Deploy Status" >> $GITHUB_STEP_SUMMARY

echo "| Type        | Resource Name  | File    | Status  |" >> $GITHUB_STEP_SUMMARY
echo "|-------------|----------------|---------|---------|" >> $GITHUB_STEP_SUMMARY

echo "Files to apply:"
echo $FILES_JSON | jq
echo "============================="

# -----------------------------------------------------------------------------
# Aplicação dos manifests na ordem de dependência correta:
#
#   1. Namespace — deve existir antes de qualquer outro recurso.
#   2. Recursos sem Pods (ConfigMap, Service, Ingress, etc.) — sem rollout.
#   3. Recursos com Pods (Deployment, DaemonSet, ReplicaSet, Pod) — com rollout.
#   4. ScaledObject (KEDA) — deve ser aplicado por último pois depende do
#      Deployment existir para não falhar.
# -----------------------------------------------------------------------------

# Passo 1: aplica Namespaces primeiro (sem rollout, pois não possuem Pods).
if echo -n "$FILES_JSON" | jq -e '.Namespace' > /dev/null; then
  artifactType "Namespace" false
fi

# Passo 2: aplica todos os demais tipos que não são Pods nem ScaledObject.
for type in $(echo -n "$FILES_JSON" | jq -cr 'keys[]'); do
  #Verifica se o type não é o tipo Namespace, que já foi aplicado, e se não são artefatos que contém pod para aplicar por último
  if [[ "$type" != "Namespace" ]] && \
     [[ "$type" != "ScaledObject" ]] && \
     [[ "$type" != "Deployment" ]] && \
     [[ "$type" != "ReplicaSet" ]] && \
     [[ "$type" != "DaemonSet" ]] && \
     [[ "$type" != "Pod" ]]; then
    artifactType $type false
  fi
done

# Passo 3: aplica os recursos que gerenciam Pods, habilitando o rollout
# quando KUBE_ROLLOUT=true para acompanhar a subida dos containers.
pods_artifacts=(
  "Deployment"
  "ReplicaSet"
  "DaemonSet"
  "Pod"
)

for type in ${pods_artifacts[@]}; do
  if echo -n "$FILES_JSON" | jq -e ".$type" > /dev/null; then
    if [ "$KUBE_ROLLOUT" = true ]; then
      artifactType $type true
    else
      artifactType $type false
    fi
  fi
done

# Passo 4: aplica ScaledObject por último (KEDA).
# O ScaledObject referencia um Deployment existente; aplicá-lo antes
# do Deployment causar ia erro no KEDA.
last_apply=(
  "ScaledObject"
)

for type in ${last_apply[@]}; do
  if echo -n "$FILES_JSON" | jq -e ".$type" > /dev/null; then
    artifactType $type false
  fi
done

# Fecha a tabela de deploy no resumo do GitHub Actions.
echo "" >> $GITHUB_STEP_SUMMARY

# -----------------------------------------------------------------------------
# Tabela de rollout no resumo do GitHub Actions.
# Exibida apenas quando KUBE_ROLLOUT=true; mostra tipo, nome, arquivo,
# tempo de execução e status (Passed/Failed) de cada rollout realizado.
# -----------------------------------------------------------------------------
if [ "$KUBE_ROLLOUT" == "true" ]; then

  echo "---" >> $GITHUB_STEP_SUMMARY

  echo "## Rollout Status" >> $GITHUB_STEP_SUMMARY

  echo "| Type        | Resource Name  | File            | Execution Time  | Status  |" >> $GITHUB_STEP_SUMMARY
  echo "|-------------|----------------|-----------------|-----------------|---------|" >> $GITHUB_STEP_SUMMARY

  # Itera sobre o array KUBE_ROLLOUT_JSON acumulado durante os applies.
  for e in ${KUBE_ROLLOUT_JSON[@]}; do

    kr_type="$(echo -n $e | jq -r .type)"
    kr_resource_name="$(echo -n $e | jq -r .resource_name)"
    kr_file="$(echo -n $e | jq -r .file)"
    kr_time="$(echo -n $e | jq -r .time)"
    kr_status="$(echo -n $e | jq -r .status)"

    echo -n "| $kr_type " >> $GITHUB_STEP_SUMMARY
    echo -n "| $kr_resource_name " >> $GITHUB_STEP_SUMMARY
    echo -n "| $kr_file " >> $GITHUB_STEP_SUMMARY
    echo -n "| $kr_time " >> $GITHUB_STEP_SUMMARY
    if $kr_status; then
      echo "| "Passed :white_check_mark:" |" >> $GITHUB_STEP_SUMMARY
    else
      echo "| Failed :x: |" >> $GITHUB_STEP_SUMMARY
      KUBE_ROLLOUT_FAILED=true
      # Interrompe imediatamente se CONTINUE_IF_FAIL=false.
      if ! $CONTINUE_IF_FAIL; then
        exit 1
      fi
    fi

  done

fi

# Se algum rollout falhou e CONTINUE_IF_FAIL=true (script chegou até aqui),
# garante que o exit code final seja 1 para sinalizar falha ao GitHub Actions.
if $KUBE_ROLLOUT_FAILED; then
  exit 1
fi

echo ""
echo "All done! =D"
