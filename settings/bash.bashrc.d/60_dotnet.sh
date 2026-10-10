# shellcheck shell=sh
if [ -d "/usr/share/dotnet" ]; then
    export DOTNET_ROOT=/usr/share/dotnet
    # Skipped when already there, so sourcing this again does not grow PATH.
    case ":$PATH:" in
        *":$DOTNET_ROOT:"*) ;;
        *) PATH="$PATH:$DOTNET_ROOT" ;;
    esac
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
