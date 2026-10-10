# shellcheck shell=sh
# Depends on _bashrc_d_path_append from 45_path-helpers.sh, sourced ahead of
# this file.
if [ -d "/usr/share/dotnet" ]; then
    export DOTNET_ROOT=/usr/share/dotnet
    _bashrc_d_path_append "$DOTNET_ROOT"
fi

# Dotnet settings
export DOTNET_NOLOGO=true
export DOTNET_PRINT_TELEMETRY_MESSAGE=false
export DOTNET_JitCollect64BitCounts=1
export DOTNET_ReadyToRun=0
export DOTNET_TC_QuickJitForLoops=1
export DOTNET_TC_CallCountingDelayMs=0
export DOTNET_TieredPGO=1
export MSBUILDTERMINALLOGGER=auto
export SuppressNETCoreSdkPreviewMessage=true
