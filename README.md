# Cluster Kubernetes com HPA

Este repositório demonstra um fluxo completo de deployment PHP/Apache em um cluster `k3d`, com Horizontal Pod Autoscaler (HPA) e captura de métricas via Metrics Server. Abaixo estão os passos para reproduzir a instalação, gerar carga e analisar as métricas coletadas com CPU diferente de zero.

## Pré-requisitos
- Docker CE em execução
- `k3d` e `kubectl` instalados e no `PATH`
- Porta `8080` livre na máquina local

## Provisionando o cluster e a aplicação
```bash
cd /home/lidia/Cluster-Kubernetes-HPA
./src/setup.sh
```
O script cria o cluster `mycluster`, builda a imagem `php-apache-k8s:v1`, importa-a para o cluster e aplica Deployment, Service e HPA. Ao final, o cluster está disponível em `http://localhost:8080/`.

## Gerando carga (para métricas de CPU > 0)
1. Em um terminal separado, faça port-forward do serviço diretamente para evitar que o tráfego pare no Traefik do k3d:
   ```bash
   kubectl port-forward svc/php-apache-service 8080:80
   ```
2. No diretório `src/`, rode o script de carga por 3 minutos com 80 conexões simultâneas:
   ```bash
   cd /home/lidia/Cluster-Kubernetes-HPA/src
   bash scripts/load.sh 3m 80 http://localhost:8080/
   ```
   - O script cria uma pasta `outputs/<timestamp>` com logs de HPA, `kubectl top` e port-forward.
   - Exemplo de arquivos gerados: `20_hpa_watch.log`, `21_top_nodes_watch.log`, `22_top_pods_watch.log`.

## Observando métricas em tempo real
- Nodes:
  ```bash
  watch -n 5 kubectl top nodes
  ```
  Saída obtida durante o teste:
  ```
  NAME                     CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
  k3d-mycluster-agent-1    2582m        32%      508Mi           3%
  k3d-mycluster-agent-0    72m          0%       256Mi           1%
  k3d-mycluster-server-0   65m          0%       611Mi           3%
  ```

- Pods:
  ```bash
  watch -n 5 kubectl top pods -A
  ```
  Exemplo de leitura com CPU diferente de zero:
  ```
  NAMESPACE   NAME                                    CPU(cores)   MEMORY(bytes)
  kube-system traefik-5d45fc8cc9-jqtd4               2525m        173Mi
  kube-system metrics-server-5c9df4bf4b-2bg5t         7m          72Mi
  default     php-apache-deployment-66f8c5bb45-k5dr2  1m          10Mi
  ```
  Observação: enquanto o tráfego passa pelo Traefik, ele é o principal consumidor de CPU. Ao direcionar o tráfego via port-forward, a carga também aparece no pod `php-apache`.

## Entendendo as métricas
- **CPU(cores)**: valor em millicores (m) devolvido pelo Metrics Server. `2525m` equivale a ~2,5 vCPUs ocupadas em tempo real. Esse pico foi observado no pod do Traefik porque o teste apontou para `http://localhost:8080/` sem port-forward, fazendo o balanceador processar todas as requisições. Quando o tráfego é redirecionado para o Service com `kubectl port-forward`, o consumo de `php-apache` sobe (ex.: `120m` ≈ 0,12 vCPU), evidenciando o impacto direto da carga na aplicação.
- **CPU(%)** nos nodes: percentual relativo à capacidade total daquele nó. Os nós `k3d` têm por padrão 8 vCPUs. Assim, o valor de `32%` no `k3d-mycluster-agent-1` representa aproximadamente `0,32 × 8 ≈ 2,5` vCPUs ativas, coerente com os `2525m` reportados no Traefik. Valores próximos de zero nos outros nós indicam que o scheduler concentrou o deployment alvo em um único worker.
- **MEMORY(bytes)**: memória residente usada pelo processo. No teste, `173Mi` no Traefik mostra que mesmo sob carga a utilização ficou bem abaixo de “limites” (nenhum limite explícito configurado). Já o pod PHP ficou em ~`10Mi`, sinalizando que a aplicação é leve e a pressão principal é CPU.
- **MEMORY(%)**: percentual da RAM disponível no nó. `3%` em `k3d-mycluster-agent-1` indica que ainda existe ampla folga; mesmo com ~500 Mi usados, o nó tem vários GiB livres. Monitorar esse número ajuda a identificar gargalos de memória que poderiam impedir o HPA de escalar.
- **Eventos do HPA**: saídas como `SuccessfulRescale` em `kubectl describe hpa` confirmam que a média de CPU ultrapassou a meta (`50%` de 100m = 50m). Se o HPA continua em `AbleToScale=True` e `ScalingLimited=False`, significa que as réplicas estão acompanhando a demanda.
- **Logs gerados pelos scripts**:
  - `20_hpa_watch.log`: registra, a cada intervalo, o `CURRENT / TARGET` do HPA para evidenciar quando a CPU passa de zero.
  - `21_top_nodes_watch.log` e `22_top_pods_watch.log`: preservam o histórico de consumo para anexar à entrega.
  - `23_metrics_api_default.jsonl`: resposta crua de `metrics.k8s.io`, útil para comprovar que os valores em millicores foram capturados diretamente da API.

## Validando o HPA
```bash
kubectl describe hpa php-apache-hpa
```
Verifique os campos **Metrics** e **Events**. Após o teste, a seção de eventos deve conter registros `SuccessfulRescale` quando a CPU média ultrapassar a meta de 50% das requests (100m por pod).

## Captura detalhada de métricas (opcional)
Use o script automatizado para instalar/atualizar o Metrics Server, coletar métricas da API e salvar snapshots:
```bash
cd /home/lidia/Cluster-Kubernetes-HPA/src
bash scripts/metrics.sh 180 5 default
```
Os dados ficam em `src/outputs/<timestamp>` e incluem:
- `20_hpa_watch.log`: evolução do HPA
- `21_top_nodes_watch.log` e `22_top_pods_watch.log`: histórico de CPU/memória
- `23_metrics_api_default.jsonl`: dump cru da API `metrics.k8s.io`
- `31_hpa_describe.txt`: eventos completos do HPA

## Encerrando o ambiente
```bash
k3d cluster delete mycluster
```
Isso remove o cluster e libera os recursos locais.
