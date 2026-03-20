cat#!/bin/bash

# ==============================================================================
# DIAGNÓSTICO COMPLETO: ZABBIX PROXY (REDE, VPN, SISTEMA, LOGS E TUNING)
# ==============================================================================

# --- AJUSTE SUAS VARIÁVEIS AQUI ---
SERVER_IP="8.8.8.8"
SERVER_PORT="10051"
PROXY_CONF="/etc/zabbix/zabbix_proxy.conf"
PROXY_LOG="/var/log/zabbix/zabbix_proxy.log"

# --- CORES ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Exigir root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERRO] Por favor, rode este script como root (sudo).${NC}"
  exit 1
fi

echo -e "${CYAN}======================================================================${NC}"
echo -e "${CYAN}           ANALISADOR AVANÇADO DE ZABBIX PROXY SOBRE VPN              ${NC}"
echo -e "${CYAN}======================================================================${NC}\n"

# ------------------------------------------------------------------------------
# 1. INFORMAÇÕES DO SISTEMA E SERVIÇO
# ------------------------------------------------------------------------------
echo -e "${YELLOW}>>> [1] STATUS DO SISTEMA E SERVIÇO <<<${NC}"
OS_NAME=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)
KERNEL_VER=$(uname -r)
echo -e "Sistema: ${GREEN}$OS_NAME${NC} | Kernel: ${GREEN}$KERNEL_VER${NC}"

if systemctl is-active --quiet zabbix-proxy; then
    echo -e "Serviço zabbix-proxy: ${GREEN}[RODANDO]${NC}"
else
    echo -e "Serviço zabbix-proxy: ${RED}[PARADO/FALHA]${NC} - Verifique: systemctl status zabbix-proxy"
fi

# ------------------------------------------------------------------------------
# 2. SEGURANÇA E TEMPO (Corrigido para multilinguagem)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}>>> [2] VERIFICAÇÃO DE TEMPO E SELINUX <<<${NC}"
if command -v timedatectl &> /dev/null; then
    NTP_SYNC=$(timedatectl show --property=NTPSynchronized --value)
    if [ "$NTP_SYNC" == "yes" ]; then
        echo -e "Sincronismo NTP: ${GREEN}[OK]${NC} ($(date '+%Y-%m-%d %H:%M:%S'))"
    else
        echo -e "Sincronismo NTP: ${RED}[FALHA]${NC} - O Proxy rejeitará/atrasará dados se o relógio não bater com o Server."
    fi
fi

if command -v getenforce &> /dev/null; then
    SESTATUS=$(getenforce)
    if [ "$SESTATUS" == "Enforcing" ]; then
        echo -e "SELinux: ${RED}[ENFORCING]${NC} - Pode bloquear sockets e portas não padrão."
    else
        echo -e "SELinux: ${GREEN}[$SESTATUS]${NC}"
    fi
fi

# ------------------------------------------------------------------------------
# 3. CAMADA DE REDE E VPN (MTU Inteligente e Correção do Ncat)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}>>> [3] DIAGNÓSTICO DE REDE E TÚNEL VPN <<<${NC}"
ROTA=$(ip route get $SERVER_IP 2>/dev/null)
if [ -n "$ROTA" ]; then
    INTERFACE=$(echo $ROTA | grep -oP 'dev \K\S+')
    echo -e "Interface de saída para $SERVER_IP: ${GREEN}$INTERFACE${NC}"
else
    echo -e "${RED}[ERRO] Sem rota para o Zabbix Server ($SERVER_IP).${NC}"
fi

# Netcat (Lendo a string de saída para evitar falso negativo do Ncat)
if nc -z -v -w 5 $SERVER_IP $SERVER_PORT 2>&1 | grep -iqE "connected|succeed"; then
    echo -e "Porta TCP $SERVER_PORT no Server: ${GREEN}[ABERTA / CONECTADA]${NC}"
else
    echo -e "Porta TCP $SERVER_PORT no Server: ${RED}[BLOQUEADA/FECHADA]${NC} - Verifique firewalls (FortiGate/iptables)."
fi

# Teste de conectividade ICMP e validação real do MTU
if ping -c 1 -W 2 $SERVER_IP &> /dev/null; then
    LOCAL_MTU=$(cat /sys/class/net/$INTERFACE/mtu 2>/dev/null)
    echo -e "MTU local da interface $INTERFACE: ${CYAN}${LOCAL_MTU}${NC}"

    if [ "$LOCAL_MTU" == "1500" ]; then
        echo -n "Teste de MTU (1500 bytes c/ flag DF): "
        if ping -c 1 -M do -s 1472 -W 2 $SERVER_IP &> /dev/null; then
            echo -e "${GREEN}[OK] (Túnel suporta pacotes completos)${NC}"
        else
            echo -e "${RED}[FALHA - FRAGMENTAÇÃO]${NC} -> ${YELLOW}Altere o MTU da $INTERFACE para 1400.${NC}"
        fi
    elif [ "$LOCAL_MTU" == "1400" ]; then
        echo -n "Teste de MTU (1400 bytes c/ flag DF): "
        if ping -c 1 -M do -s 1372 -W 2 $SERVER_IP &> /dev/null; then
            echo -e "${GREEN}[OK] (MTU já está ajustado e passando pelo túnel)${NC}"
        else
            echo -e "${RED}[FALHA] Não passa nem o pacote de 1400 bytes. Verifique a VPN.${NC}"
        fi
    else
        echo -e "${YELLOW}[INFO] MTU customizado ($LOCAL_MTU). Teste de fragmentação padrão ignorado.${NC}"
    fi
else
    echo -e "Teste de MTU (ICMP): ${YELLOW}[IGNORADO] - O firewall/VPN está bloqueando pacotes ICMP (Ping).${NC}"
fi

# ------------------------------------------------------------------------------
# 4. LEITURA DE CONFIGURAÇÃO E TUNING BÁSICO
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}>>> [4] ANÁLISE DO ZABBIX_PROXY.CONF E TUNING <<<${NC}"
if [ -f "$PROXY_CONF" ]; then
    HOSTNAME=$(grep -E "^Hostname=" $PROXY_CONF | cut -d'=' -f2)
    echo -e "Hostname configurado: ${CYAN}$HOSTNAME${NC} (Deve ser idêntico ao Frontend do Server - Case Sensitive)"

    # Extrair valores de Tuning
    CACHE_SIZE=$(grep -E "^CacheSize=" $PROXY_CONF | cut -d'=' -f2)
    HIST_CACHE=$(grep -E "^HistoryCacheSize=" $PROXY_CONF | cut -d'=' -f2)
    POLLERS=$(grep -E "^StartPollers=" $PROXY_CONF | cut -d'=' -f2)
    DATA_FREQ=$(grep -E "^DataSenderFrequency=" $PROXY_CONF | cut -d'=' -f2)

    echo -e "\nParâmetros de Performance Encontrados:"
    [ -z "$CACHE_SIZE" ] && echo -e "- CacheSize: ${YELLOW}8M (Padrão - Pode ser baixo para muitos hosts)${NC}" || echo "- CacheSize: $CACHE_SIZE"
    [ -z "$HIST_CACHE" ] && echo -e "- HistoryCacheSize: ${YELLOW}16M (Padrão)${NC}" || echo "- HistoryCacheSize: $HIST_CACHE"
    [ -z "$POLLERS" ] && echo -e "- StartPollers: ${YELLOW}5 (Padrão)${NC}" || echo "- StartPollers: $POLLERS"

    if [ "$DATA_FREQ" == "1" ]; then
        echo -e "- DataSenderFrequency: ${RED}1 segundo${NC} -> Muito agressivo para links de VPN. Considere 10 ou mais."
    else
        [ -z "$DATA_FREQ" ] && echo "- DataSenderFrequency: 1 (Padrão)" || echo "- DataSenderFrequency: $DATA_FREQ"
    fi
else
    echo -e "${RED}[ERRO] Arquivo de configuração não encontrado em $PROXY_CONF${NC}"
fi

# ------------------------------------------------------------------------------
# 5. ANÁLISE DE LOGS E DADOS PRESOS
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}>>> [5] RX/TX DOS LOGS (Últimas 500 linhas) <<<${NC}"
if [ -f "$PROXY_LOG" ]; then
    echo "Buscando erros críticos de comunicação, MTU ou memória..."
    ERROS=$(tail -n 500 $PROXY_LOG | egrep -i "timeout|refused|cannot connect|denied|failed|network error|out of memory")

    if [ -n "$ERROS" ]; then
        echo -e "${YELLOW}Avisos encontrados no log (Valide se são erros antigos ou atuais):${NC}"
        echo "$ERROS" | tail -n 10
    else
        echo -e "${GREEN}[OK] O log está limpo nas últimas 500 linhas. Nenhuma falha óbvia registrada.${NC}"
    fi
else
    echo -e "${RED}[ERRO] Arquivo de log não encontrado em $PROXY_LOG${NC}"
fi

# ------------------------------------------------------------------------------
# 6. SOCKETS ATIVOS
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}>>> [6] CONEXÕES ATIVAS COM O SERVER <<<${NC}"
CONEXOES=$(ss -tunap | grep "$SERVER_IP:$SERVER_PORT" | grep zabbix)
if [ -n "$CONEXOES" ]; then
    echo -e "${GREEN}Sockets de comunicação estabelecidos:${NC}"
    echo "$CONEXOES" | awk '{print "Estado: "$1" | Local: "$4" | Remoto: "$5}'
else
    echo -e "${YELLOW}[ALERTA] Nenhum socket ativo no momento conversando com o Server.${NC}"
fi

echo -e "\n${CYAN}======================================================================${NC}"
echo -e "${CYAN}                 DIAGNÓSTICO CONCLUÍDO                                ${NC}"
echo -e "${CYAN}======================================================================${NC}\n"
