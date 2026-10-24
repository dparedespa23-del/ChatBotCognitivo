param([switch]$Verificar)
$ErrorActionPreference = 'Stop'
$raizProyecto = $PSScriptRoot
$carpetaBackend = Join-Path $raizProyecto 'backend\principal'
$carpetaFrontend = Join-Path $raizProyecto 'frontend'
$pythonProyecto = Join-Path $raizProyecto 'backend\.venv\Scripts\python.exe'
$carpetaLogs = Join-Path $raizProyecto 'logs'
$carpetaProgramas = Join-Path $env:LOCALAPPDATA 'ChatbotCognitivo\runtimes'
$carpetaDescargas = Join-Path $env:LOCALAPPDATA 'ChatbotCognitivo\descargas'
$procesosProyecto = New-Object System.Collections.ArrayList
$variablesAnteriores = @{}
$bloqueoProyecto = $null
$codigoSalidaProyecto = 0

function BuscarPrograma([string]$nombre, [string[]]$alternativas = @()) {
    $comando = Get-Command $nombre -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($comando) { return $comando.Source }
    foreach ($ruta in $alternativas) {
        if (Test-Path -LiteralPath $ruta -PathType Leaf) { return $ruta }
    }
    return $null
}
function DetenerProcesoProyecto([int]$idProceso, [datetime]$inicioEsperado) {
    # Solo se detienen los procesos iniciados por esta ventana.
    $proceso = Get-Process -Id $idProceso -ErrorAction SilentlyContinue
    if (-not $proceso) { return }
    if ([Math]::Abs(($proceso.StartTime.ToUniversalTime() - $inicioEsperado.ToUniversalTime()).TotalMilliseconds) -gt 2) { return }
    $hijos = Get-CimInstance Win32_Process -Filter "ParentProcessId = $idProceso" -ErrorAction SilentlyContinue
    foreach ($hijo in $hijos) { DetenerProcesoProyecto ([int]$hijo.ProcessId) ([datetime]$hijo.CreationDate) }
    Stop-Process -Id $idProceso -ErrorAction SilentlyContinue
}
function RegistrarProceso($proceso) {
    [void]$procesosProyecto.Add(@{ Id = $proceso.Id; Inicio = $proceso.StartTime })
    return $proceso
}
function EsperarServicio([string]$url, [string]$campo, [string]$valor, $proceso, [int]$segundos = 90) {
    $limite = (Get-Date).AddSeconds($segundos)
    while ((Get-Date) -lt $limite) {
        if ($proceso) {
            $proceso.Refresh()
            if ($proceso.HasExited) { throw "Un servicio se cerro. Revisa los archivos de $carpetaLogs" }
        }
        try {
            $respuesta = Invoke-RestMethod -Uri $url -TimeoutSec 2
            if ($null -ne $respuesta.$campo -and ($valor -eq '' -or $respuesta.$campo -eq $valor)) { return }
        } catch { }
        Start-Sleep -Milliseconds 400
    }
    throw "No respondio $url. Revisa logs/ y vuelve a iniciar."
}
try {
    Write-Host 'CHATBOT COGNITIVO - INICIO LOCAL' -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $carpetaLogs -Force | Out-Null
    try {
        $bloqueoProyecto = [System.IO.File]::Open((Join-Path $carpetaLogs 'inicio.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    } catch { throw 'Otra ventana ya esta iniciando o ejecutando este proyecto. Revisa esa ventana.' }
    . (Join-Path $raizProyecto 'herramientas\instalar_dependencias.ps1')
    # TLS para las descargas oficiales; no se modifica la validacion de certificados.
    $tlsAnteriorProyecto = [Net.ServicePointManager]::SecurityProtocol
    [Net.ServicePointManager]::SecurityProtocol = $tlsAnteriorProyecto -bor [Net.SecurityProtocolType]::Tls12
    # Configuracion del proceso local; no lee ni modifica el .env de produccion.
    $variablesLocales = @{
        DJANGO_DEBUG = 'true'
        DJANGO_ALLOWED_HOSTS = 'localhost,127.0.0.1,[::1]'
        DJANGO_CSRF_TRUSTED_ORIGINS = 'http://localhost:5173,http://127.0.0.1:5173'
        DJANGO_SECURE_SSL_REDIRECT = 'false'
        DJANGO_COOKIE_SECURE = 'false'
        DJANGO_TRUST_PROXY_HEADERS = 'false'
        DJANGO_DB_PATH = (Join-Path $carpetaBackend 'db.sqlite3')
        OLLAMA_URL = 'http://127.0.0.1:11434'
        OLLAMA_HOST = '127.0.0.1:11434'
        OLLAMA_MODEL = 'deepseek-r1:8b'
        NODE_ENV = 'development'
        PYTHONIOENCODING = 'utf-8'
    }
    foreach ($nombre in $variablesLocales.Keys) {
        $variablesAnteriores[$nombre] = [Environment]::GetEnvironmentVariable($nombre, 'Process')
        [Environment]::SetEnvironmentVariable($nombre, $variablesLocales[$nombre], 'Process')
    }
    foreach ($puerto in @(8000, 5173)) {
        if (Get-NetTCPConnection -State Listen -LocalPort $puerto -ErrorAction SilentlyContinue) {
            throw "El puerto $puerto esta ocupado. Cierra el otro inicio local y vuelve a intentarlo."
        }
    }
    $node = BuscarPrograma 'node.exe' @((Join-Path $env:ProgramFiles 'nodejs\node.exe'))
    $versionNode = [version]'0.0.0'
    if ($node) {
        try { $versionNode = [version]((& $node --version).Trim().TrimStart('v')) } catch { }
    }
    if (-not (($versionNode.Major -eq 20 -and $versionNode.Minor -ge 19) -or $versionNode -ge [version]'22.12.0')) {
        $node = InstalarNodeLocal
    }
    $npm = Join-Path (Split-Path $node) 'npm.cmd'
    if (-not (Test-Path -LiteralPath $npm)) { $npm = BuscarPrograma 'npm.cmd' }
    if (-not $npm) {
        $node = InstalarNodeLocal
        $npm = Join-Path (Split-Path $node) 'npm.cmd'
    }
    $variablesAnteriores['PATH'] = $env:PATH
    $env:PATH = (Split-Path $node) + ';' + $env:PATH

    $pythonValido = $false
    if (Test-Path -LiteralPath $pythonProyecto) {
        try {
            $versionPython = (& $pythonProyecto --version 2>$null | Out-String).Trim()
            $pythonValido = $LASTEXITCODE -eq 0 -and $versionPython -match '^Python 3\.(\d+)\.' -and [int]$Matches[1] -ge 12
        } catch { }
    }
    if (-not $pythonValido) {
        Write-Host '[1/5] Preparando Python por primera vez...'
        $seleccionPython = BuscarPythonLocal
        if (-not $seleccionPython) { $seleccionPython = InstalarPythonLocal }
        $pythonSistema = $seleccionPython.Ruta
        $argumentosPython = $seleccionPython.Args
        $entorno = Join-Path $raizProyecto 'backend\.venv'
        if (Test-Path -LiteralPath $entorno) {
            # Conserva un entorno copiado o danado, en vez de borrarlo.
            $esperado = [IO.Path]::GetFullPath((Join-Path $raizProyecto 'backend\.venv'))
            if ((Resolve-Path -LiteralPath $entorno).Path -ne $esperado) { throw 'La ruta del entorno Python no coincide con este proyecto.' }
            Move-Item -LiteralPath $entorno -Destination (Join-Path $carpetaLogs ('entorno-anterior-' + [guid]::NewGuid().ToString('N')))
        }
        & $pythonSistema @argumentosPython -m venv (Join-Path $raizProyecto 'backend\.venv')
        if ($LASTEXITCODE -ne 0) { throw 'No se pudo crear el entorno Python del proyecto.' }
    }
    Write-Host '[1/5] Comprobando las dependencias de Python...'
    & $pythonProyecto -m pip install --disable-pip-version-check -r (Join-Path $raizProyecto 'backend\requirements.txt')
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo preparar Python. Revisa Internet; no copies backend/.venv desde otro equipo.' }

    $huellaReact = (Get-FileHash -LiteralPath (Join-Path $carpetaFrontend 'package-lock.json') -Algorithm SHA256).Hash + (Get-FileHash -LiteralPath (Join-Path $carpetaFrontend 'package.json') -Algorithm SHA256).Hash
    $marcaReact = Join-Path $carpetaLogs 'dependencias-react.sha256'
    if (-not (Test-Path -LiteralPath (Join-Path $carpetaFrontend 'node_modules\.bin\vite.cmd')) -or -not (Test-Path -LiteralPath $marcaReact) -or (Get-Content -LiteralPath $marcaReact -Raw).Trim() -ne $huellaReact) {
        Write-Host '[2/5] Instalando las dependencias de la interfaz...'
        Push-Location $carpetaFrontend
        try {
            & $npm ci --include=dev --no-fund --no-audit
            if ($LASTEXITCODE -ne 0) { throw 'No se pudo preparar React. Revisa Internet y package-lock.json.' }
        } finally { Pop-Location }
        Set-Content -LiteralPath $marcaReact -Value $huellaReact -Encoding ASCII
    }

    Write-Host '[3/5] Comprobando Ollama y deepseek-r1:8b...'
    $ollama = BuscarPrograma 'ollama.exe' @((Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'), (Join-Path $env:ProgramFiles 'Ollama\ollama.exe'))
    $modelos = $null
    try { $modelos = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 2 } catch { }
    if ($null -eq $modelos) {
        if (-not $ollama) {
            $ollama = InstalarOllamaLocal
            try { $modelos = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 2 } catch { }
        }
    }
    if ($null -eq $modelos) {
        Write-Host 'Iniciando Ollama; la deteccion del equipo puede tardar un momento...'
        $servicioOllama = RegistrarProceso (Start-Process -FilePath $ollama -ArgumentList 'serve' -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $carpetaLogs 'ollama.log') -RedirectStandardError (Join-Path $carpetaLogs 'ollama-error.log'))
        EsperarServicio 'http://127.0.0.1:11434/api/tags' 'models' '' $null 180
        $modelos = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 3
    }
    if (-not @($modelos.models | Where-Object { $_.name -eq 'deepseek-r1:8b' }).Count) {
        if (-not $ollama) { $ollama = InstalarOllamaLocal }
        Write-Host 'Primera descarga del modelo: unos 5 GB. Espera a que termine; no cierres esta ventana.' -ForegroundColor Yellow
        & $ollama pull deepseek-r1:8b
        if ($LASTEXITCODE -ne 0) { throw 'La descarga no termino. Revisa Internet y vuelve a iniciar para reanudarla.' }
        $modelos = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 5
        if (-not @($modelos.models | Where-Object { $_.name -eq 'deepseek-r1:8b' }).Count) { throw 'Ollama no confirma que el modelo este descargado.' }
    }

    Write-Host '[4/5] Preparando la base local e iniciando el backend...'
    & $pythonProyecto (Join-Path $carpetaBackend 'manage.py') migrate --noinput
    if ($LASTEXITCODE -ne 0) { throw 'No se pudieron preparar las tablas de Django.' }
    $backend = RegistrarProceso (Start-Process -FilePath $pythonProyecto -ArgumentList @('manage.py', 'iniciar_backend') -WorkingDirectory $carpetaBackend -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $carpetaLogs 'backend.log') -RedirectStandardError (Join-Path $carpetaLogs 'backend-error.log'))
    EsperarServicio 'http://127.0.0.1:8000/api/salud/' 'estado' 'ok' $backend

    Write-Host '[5/5] Iniciando la interfaz...'
    # Se protegen las rutas con espacios, apostrofes y caracteres especiales.
    $rutaReactSegura = $carpetaFrontend.Replace("'", "''")
    $rutaNpmSegura = $npm.Replace("'", "''")
    $ordenReact = "Set-Location -LiteralPath '$rutaReactSegura'; & '$rutaNpmSegura' run dev -- --host 127.0.0.1; exit " + '$LASTEXITCODE'
    $ordenCodificada = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ordenReact))
    $powershellWindows = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $frontend = RegistrarProceso (Start-Process -FilePath $powershellWindows -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $ordenCodificada) -WorkingDirectory $carpetaFrontend -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $carpetaLogs 'frontend.log') -RedirectStandardError (Join-Path $carpetaLogs 'frontend-error.log'))
    EsperarServicio 'http://127.0.0.1:5173/api/salud/' 'estado' 'ok' $frontend
    $pagina = Invoke-WebRequest -Uri 'http://127.0.0.1:5173' -UseBasicParsing -TimeoutSec 10
    if ($pagina.StatusCode -ne 200 -or $pagina.Content -notmatch 'id="root"') { throw 'La pantalla de React no se pudo cargar.' }
    $csrf = Invoke-RestMethod -Uri 'http://127.0.0.1:5173/api/csrf/' -TimeoutSec 5
    if (-not $csrf.csrfToken) { throw 'La interfaz no pudo comunicarse con Django.' }
    Write-Host ''
    Write-Host 'LISTO: http://localhost:5173' -ForegroundColor Green
    Write-Host 'Panel: http://localhost:5173/administrador'
    if ($Verificar) {
        Write-Host 'VERIFICACION CORRECTA: modelo, base local, backend, interfaz y comunicacion API.' -ForegroundColor Green
    } else {
        Start-Process 'http://localhost:5173'
        Write-Host 'Deja esta ventana abierta mientras uses el programa.'
        [void](Read-Host 'Para apagar el programa, vuelve aqui y presiona ENTER')
    }
} catch {
    $codigoSalidaProyecto = 1
    Write-Host ''
    Write-Host ('No se pudo iniciar: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host 'Los detalles de los servicios quedan en logs/.'
} finally {
    for ($indice = $procesosProyecto.Count - 1; $indice -ge 0; $indice--) {
        $registro = $procesosProyecto[$indice]
        DetenerProcesoProyecto $registro.Id $registro.Inicio
    }
    foreach ($nombre in $variablesAnteriores.Keys) {
        [Environment]::SetEnvironmentVariable($nombre, $variablesAnteriores[$nombre], 'Process')
    }
    if ($bloqueoProyecto) { $bloqueoProyecto.Dispose() }
    if ($null -ne $tlsAnteriorProyecto) { [Net.ServicePointManager]::SecurityProtocol = $tlsAnteriorProyecto }
}
exit $codigoSalidaProyecto
