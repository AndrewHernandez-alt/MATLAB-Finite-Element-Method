%% ANALISIS DE ELEMENTO FINITO ESTRUCTURAL 3D (EULER-BERNOULLI)
%estres.py — Análisis de Elemento Finito Estructural 3D
%=======================================================
%Euler-Bernoulli | Superposición Modal | Respuesta en Frecuencia
%
%ECUACIÓN DE MOVIMIENTO RESUELTA
%────────────────────────────────
%  M·ü(t) + C·u̇(t) + K·u(t) = F₀·e^(iωt) + F_esc(t) + F_grav
%
%  Término     | Símbolo     | Descripción
%  ────────────────────────────────────────────────────────────────
%  Inercia     | M·ü         | Matriz Consistente (Masa distribuida de viga + Momento Polar J)
%  Amort.      | C·u̇         | Amortiguamiento modal ζ_r ponderado por Energía de Deformación
%  Rigidez     | K·u         | Viga E-B 3D: axial + torsión + flexión
%  Armónica    | F₀·e^(iωt)  | Espectro Fourier de la carga medida
%  Escalón     | F_esc(t)    | Pulso 3D con inicio/fin: A·[H(t−t_i) - H(t−t_f)]
%  Gravedad    | F_grav      | −M_nodal·g·ê_z (deflexión estática)
%
%ARCHIVOS DE ENTRADA (Excel)
%────────────────────────────
%  Hoja "Nodos"
%    Columnas requeridas: ID, X (m), Y (m), Z (m),
%                         MasaX (kg), MasaY (kg), MasaZ (kg),
%                         FixX, FixY, FixZ, FixRX, FixRY, FixRZ
%
%  Hoja "Elementos"
%    Columnas requeridas: ID, NodoI, NodoJ, Area (m2), E (Pa), G (Pa),
%                         J (m4), Iy (m4), Iz (m4)
%   Columnas opcionales: Zeta, Sigma_y, Sigma_u
%
%  Hoja "Carga_Fourier" (Opcional)
%    Columnas requeridas: Frecuencia (Hz), Amplitud (m), Fase (rad)
%    Descripción        : Espectro de la carga de entrada medida
%
%  Hoja "Carga_Escalon" (Opcional)
%    Columnas requeridas: Nodo_Aplicacion, Magnitud_x (N), Magnitud_y (N), Magnitud_z (N),
%                         Tiempo_Inicio (s), Tiempo_Final (s)
%  Hoja "Graficas" (Opcional)
%    Columnas requeridas: Grafica, Exportar (s/n)
%    Columnas opcionales: C_y (m), C_z (m), Z_p (m3),
%                         Zeta (amortiguamiento),
%                        Sigma_y (Pa), Sigma_u (Pa)
%
%ARCHIVOS GENERADOS (Carpeta Resultados_Analisis/)
%─────────────────────────────────────────────────
%resultados_analisis.xlsx  — Reporte principal Excel (9 hojas)
%graficas/                  — Figuras PNG y animación GIF
% modos_normales/            — Imágenes de formas modales (1–6)
%  espectros_nodos/           — Espectros dinámicos por nodo

% Con calma, recuerda que esto es un maraton, no una carrera de 100 metros.
% aunque si corre a la primera no me quejop
clc; clear; close all;

 
%% 0. CONFIGURACION 
 
% MATLAB no tiene argparse nativo, una de las pocas cosas en las que no le gana a python
% asi que lo dejamos como variables de
% config arriba de todo. Si algun dia esto se vuelve funcion, aqui van
% los inputParser.
INPUT_FILE   = 'modelo_estructural.xlsx';
OUTPUT_XLSX  = 'resultados_analisis.xlsx';
FORCE_3D     = false;      % true = forzar graficas 3D aunque Z sea constante
SOLVER       = 'sparse';   % 'sparse' (eigs sigma-shift) o 'dense' (eig)
USE_SPARSE   = strcmp(SOLVER, 'sparse');

DAMPING_MIN  = 0.03;
DOF_PER_NODE = 6;
GRAVITY      = 9.81;

t0_global = tic;
elapsed = @() sprintf('%6.2fs', toc(t0_global));

 
%% GESTION DE DIRECTORIOS DE SALIDA
 
MASTER_DIR   = 'Resultados_Analisis';
GRAFICAS_DIR = fullfile(MASTER_DIR, 'graficas');
MODAL_DIR    = fullfile(MASTER_DIR, 'modos_normales');
SPEC_DIR     = fullfile(MASTER_DIR, 'espectros_nodos');

dirs_needed = {MASTER_DIR, GRAFICAS_DIR, MODAL_DIR, SPEC_DIR};
for k = 1:numel(dirs_needed)
    if ~exist(dirs_needed{k}, 'dir')
        mkdir(dirs_needed{k});
    end
end

% Aseguramos que el excel de salida caiga en la carpeta maestra
[out_path, ~, ~] = fileparts(OUTPUT_XLSX);
if isempty(out_path)
    OUTPUT_XLSX = fullfile(MASTER_DIR, OUTPUT_XLSX);
end

 
%% BANNER (porque si va a tardar, que al menos se vea profesional)
 
fprintf('%s\n', repmat('=', 1, 70));
fprintf('   ANALISIS DE ELEMENTO FINITO ESTRUCTURAL 3-D\n');
fprintf('   Euler-Bernoulli | Superposicion Modal | Respuesta en Frecuencia\n');
fprintf('\n');
fprintf('   M-u_dd + C-u_d + K-u = F0*e^(iwt) + A*H(t-t0) + F_grav\n');
fprintf('   |-- K : axial (EA/L) + torsion (GJ/L) + flexion (EI/L3)\n');
fprintf('   |-- M : masa nodal traslacional + inercia rotacional (ip2)\n');
fprintf('   |-- C : amortiguamiento modal por elemento (zeta)\n');
fprintf('   |-- F_armonica : espectro Fourier -> Carga_Fourier\n');
fprintf('   |-- F_escalon  : A*H(t-t0) -> Carga_Escalon [opcional]\n');
fprintf('   `-- F_grav     : -M*g*ez (gravedad en Z)\n');
fprintf('%s\n', repmat('=', 1, 70));
fprintf('  Entrada : %s\n', INPUT_FILE);
fprintf('  Salida  : %s\n', OUTPUT_XLSX);
fprintf('  Solver  : %s\n', SOLVER);
fprintf('  MATLAB  : %s\n', version);
fprintf('%s\n', repmat('=', 1, 70));

 
%% 1. LECTURA DE DATOS
 
fprintf('\n[%s] [PASO 1/11] Leyendo ''%s'' ...\n', elapsed(), INPUT_FILE);
fprintf('    (Nota: si el archivo es grande esto puede tardar. Ve por un cafe)\n');

if ~exist(INPUT_FILE, 'file')
    error('ERROR: No se encontro el archivo ''%s''.', INPUT_FILE);
end

sheets_disp = sheetnames(INPUT_FILE);
required_sheets = {'Nodos', 'Elementos', 'Carga_Fourier'};
missing_sheets = setdiff(required_sheets, sheets_disp);
if ~isempty(missing_sheets)
    error('ERROR: Faltan hojas en el Excel: %s', strjoin(missing_sheets, ', '));
end

node_data    = readtable(INPUT_FILE, 'Sheet', 'Nodos');
elem_data    = readtable(INPUT_FILE, 'Sheet', 'Elementos');
fourier_data = readtable(INPUT_FILE, 'Sheet', 'Carga_Fourier');

% Si no existe Carga_Escalon, seguimos sin llorar, no quiero trabarme aqui
% 10 horas como otras veces
if ismember('Carga_Escalon', sheets_disp)
    escalon_data = readtable(INPUT_FILE, 'Sheet', 'Carga_Escalon');
    fprintf('    Carga Escalon   : %d filas leidas\n', height(escalon_data));
else
    escalon_data = table();
    fprintf('    Carga Escalon   : no encontrada\n');
end

% --- Hoja Graficas (s/n) para exportacion condicional -------------
% readtable sanitiza los headers asi que los nombres de la struct de
% defaults son "amigables" (sin espacios raros) para comparar luego.
GRAF_KEYS = {'Mapa_Estres','Mapa_Deformacion','Mapa_Elementos','FS_Elementos', ...
             'FU_Elementos','Factor_DLF','Resonancia_beta','Frecuencia_Pico', ...
             'Comparacion_Frecuencia','Simulacion (10s)','Modos_Normales','Espectro_Nodos'};
GRAF = containers.Map(GRAF_KEYS, num2cell(true(1, numel(GRAF_KEYS))));

if ismember('Graficas', sheets_disp)
    gdf = readtable(INPUT_FILE, 'Sheet', 'Graficas', 'ReadVariableNames', false);
    for r = 2:height(gdf)   % fila 1 es header ("Graficas","(s/n)")
        key = char(strtrim(string(gdf{r,1})));
        val = lower(strtrim(string(gdf{r,2})));
        if isKey(GRAF, key)
            GRAF(key) = strcmp(val, 's');
        end
    end
    vals = cell2mat(values(GRAF));
    fprintf('    Hoja Graficas   : leida (%d graficas activas)\n', sum(vals));
else
    fprintf('    Hoja Graficas   : no encontrada -- exportando todo\n');
end

% --- Deteccion de columna de amplitud + unidades -------------------
% readtable convierte "Frecuencia (Hz)" -> Frecuencia_Hz_ y
% "Amplitud (mm)" -> Amplitud_mm_ (asi sanitiza matlab los headers).
% logica de prioridad  mm > m > N > generico.
vn_fourier = fourier_data.Properties.VariableNames; %#ok<NASGU> % para debug si algo truena
amp_candidates = {'Amplitud_mm_', 'Amplitud_m_', 'Amplitud_N_'};
amp_col = 'Amplitud';
for c = 1:numel(amp_candidates)
    if ismember(amp_candidates{c}, fourier_data.Properties.VariableNames)
        amp_col = amp_candidates{c};
        break;
    end
end

% Limpieza: quitar NaN y amplitudes negativas, ordenar por frecuencia
freq_col_name = 'Frecuencia_Hz_';
mask_valid = ~isnan(fourier_data.(freq_col_name)) & ~isnan(fourier_data.(amp_col));
fourier_data = fourier_data(mask_valid, :);
fourier_data = fourier_data(fourier_data.(amp_col) >= 0, :);
fourier_data = sortrows(fourier_data, freq_col_name);

freq_hz_input = fourier_data.(freq_col_name);
amp_input_raw = fourier_data.(amp_col);
omega_input   = 2 * pi * freq_hz_input;

% Determinar si la entrada es desplazamiento (m, mm) o fuerza (N), en los
% datos que nos dieron es desplazamiento (nos guiamos con nombre de la clumna)
if strcmp(amp_col, 'Amplitud_mm_') || strcmp(amp_col, 'Amplitud')
    IS_FORCE_INPUT = false;
    AMP_UNIT_LABEL = '[mm]';
    amp_N_input = amp_input_raw / 1000.0;
elseif strcmp(amp_col, 'Amplitud_m_')
    IS_FORCE_INPUT = false;
    AMP_UNIT_LABEL = '[m]';
    amp_N_input = amp_input_raw;
else
    IS_FORCE_INPUT = true;
    AMP_UNIT_LABEL = '[N]';
    amp_N_input = amp_input_raw;
end

fprintf('    Nodos           : %d\n', height(node_data));
fprintf('    Elementos       : %d\n', height(elem_data));
fprintf('    Puntos Fourier  : %d  (%.3f - %.3f Hz)\n', height(fourier_data), ...
    min(freq_hz_input), max(freq_hz_input));
fprintf('    Amplitud maxima : %.6f %s\n', max(amp_N_input), AMP_UNIT_LABEL);

 
%% 2. VALIDACION Y REPARACION DE MALLA
 
% Aqui es donde el excel te traiciona con IDs repetidos a las 3am.
fprintf('\n[%s] [PASO 2/11] Validando malla ...\n', elapsed());

mesh_errors   = {};
mesh_warnings = {};
fix_cols = {'FixX','FixY','FixZ','FixRX','FixRY','FixRZ'};

raw_ids = node_data.ID;
seen = containers.Map('KeyType','double','ValueType','double');
for pos = 1:numel(raw_ids)
    nid = raw_ids(pos);
    if isKey(seen, nid)
        all_elem_ids = union(elem_data.NodoI, elem_data.NodoJ);
        needed = setdiff(all_elem_ids, raw_ids);
        if ~isempty(needed)
            new_id = min(needed);
            msg = sprintf(['[REPARACION AUTOMATICA] Nodo duplicado ID=%d ' ...
                '(fila %d) renombrado a ID=%d.'], nid, pos+1, new_id);
            fprintf('\n  [!] %s\n', msg);
            mesh_warnings{end+1} = msg; %#ok<SAGROW>
            raw_ids(pos) = new_id;
            node_data.ID(pos) = new_id;
        else
            mesh_warnings{end+1} = sprintf( ...
                'Nodo duplicado ID=%d en fila %d: no se pudo reparar.', nid, pos+1); %#ok<SAGROW>
        end
    else
        seen(nid) = pos;
    end
end

node_ids  = node_data.ID;
x_pos     = node_data.X_m_;
y_pos     = node_data.Y_m_;
z_pos     = node_data.Z_m_;
mass_x    = node_data.MasaX_kg_;
mass_y    = node_data.MasaY_kg_;
mass_z    = node_data.MasaZ_kg_;
fix_flags = table2array(node_data(:, fix_cols));
n_nodes   = numel(node_ids);

% Mapeo ID indice base-1 (bendito seas matlab por no empezar en 0)
node_idx = containers.Map('KeyType', 'double', 'ValueType', 'double');
for i = 1:n_nodes
    node_idx(node_ids(i)) = i;
end
dof_total = DOF_PER_NODE * n_nodes;
defined_ids = node_ids;

nodos_en_elem = [];
n_elems_raw = height(elem_data);
for e = 1:n_elems_raw
    ni_id = elem_data.NodoI(e);
    nj_id = elem_data.NodoJ(e);
    nodos_en_elem = union(nodos_en_elem, [ni_id, nj_id]);
    if ~isKey(node_idx, ni_id)
        mesh_errors{end+1} = sprintf('Elemento %d: NodoI=%d no definido.', elem_data.ID(e), ni_id); %#ok<SAGROW>
    end
    if ~isKey(node_idx, nj_id)
        mesh_errors{end+1} = sprintf('Elemento %d: NodoJ=%d no definido.', elem_data.ID(e), nj_id); %#ok<SAGROW>
    end
    if isKey(node_idx, ni_id) && isKey(node_idx, nj_id)
        ni = node_idx(ni_id); nj = node_idx(nj_id);
        L = sqrt((x_pos(nj)-x_pos(ni))^2 + (y_pos(nj)-y_pos(ni))^2 + (z_pos(nj)-z_pos(ni))^2);
        if L < 1e-9
            mesh_errors{end+1} = sprintf('Elemento %d: longitud ~0.', elem_data.ID(e)); %#ok<SAGROW>
        end
    end
end
aislados = setdiff(defined_ids, nodos_en_elem);
if ~isempty(aislados)
    mesh_warnings{end+1} = sprintf('Nodos aislados: %s', mat2str(sort(aislados)')); %#ok<SAGROW>
end

is_flat_z = all(abs(z_pos - z_pos(1)) < 1e-9);
use_3d_plot = (~is_flat_z) || FORCE_3D;

if is_flat_z && ~FORCE_3D
    aviso_2d = sprintf('[AVISO 2D] Todos los nodos tienen Z=%.4g m -> graficas en 2D.', z_pos(1));
    mesh_warnings{end+1} = aviso_2d; %#ok<SAGROW>
    fprintf('\n  [AVISO 2D] Todos los nodos comparten Z=%.4g m -> graficas 2D.\n', z_pos(1));
else
    if FORCE_3D && is_flat_z
        fprintf('\n  [INFO 3D (forzado)] graficas 3D.\n');
    else
        fprintf('\n  [INFO 3D] graficas 3D.\n');
    end
end

if ~isempty(mesh_errors)
    for i = 1:numel(mesh_errors)
        fprintf('  >> ERROR: %s\n', mesh_errors{i});
    end
    error('Malla invalida, revisa los errores de arriba.');
end
if ~isempty(mesh_warnings)
    for i = 1:numel(mesh_warnings)
        if isempty(strfind(mesh_warnings{i}, 'AVISO 2D')) %#ok<STREMP>
            fprintf('  >> AVISO: %s\n', mesh_warnings{i});
        end
    end
end
fprintf('    Malla validada (%d nodos, %d elem.)\n', n_nodes, n_elems_raw);

 
%% 3. FUNCIONES DE RIGIDEZ LOCAL
%% (definidas al final del archivo, MATLAB quiere las funciones abajo)
 

 
%% 4. ENSAMBLADO M y K (matrices dispersas)
 
fprintf('\n[%s] [PASO 3/11] Ensamblando matrices M y K (%d DOF) ...\n', elapsed(), dof_total);

K_row = []; K_col = []; K_data = [];
M_row = []; M_col = []; M_data = [];
elem_info = struct([]);
n_valid = 0;

% Nombres de columnas "amigos" tal como los sanitiza readtable, con
% fallback en cascada, parecido a la idea que me mostro el profe (un saludo si esta leyendo esto a las 2:37 de la madrugada) .py (que usaba row.get(...) con
% varios nombres posibles por si el excel viene con headers distintos).
vn_elem = elem_data.Properties.VariableNames;

get_col_fallback = @(candidates, default_val, row_idx) local_get_fallback(elem_data, candidates, default_val, row_idx);

for e = 1:n_elems_raw
    elem_id = elem_data.ID(e);
    ni_id = elem_data.NodoI(e);
    nj_id = elem_data.NodoJ(e);
    if ~isKey(node_idx, ni_id) || ~isKey(node_idx, nj_id)
        continue;
    end
    ni = node_idx(ni_id);
    nj = node_idx(nj_id);

    A_sec = elem_data.Area_m2_(e);
    E     = elem_data.E_Pa_(e);
    G     = elem_data.G_Pa_(e);
    J_val = elem_data.J_m4_(e);
    Iy    = elem_data.Iy_m4_(e);
    Iz    = elem_data.Iz_m4_(e);

    zeta_elem = get_col_fallback({'Zeta_amortiguamiento_','Zeta'}, DAMPING_MIN, e);
    sigma_y   = get_col_fallback({'Sigma_y_Pa_'}, Inf, e);
    sigma_u   = get_col_fallback({'Sigma_u_Pa_'}, Inf, e);
    ymax      = get_col_fallback({'C_y_m_','ymax_m_','ymax'}, 0.0, e);
    zmax      = get_col_fallback({'C_z_m_','zmax_m_','zmax'}, 0.0, e);
    zp        = get_col_fallback({'Z_p_m3_','Zp_m3_'}, 0.0, e);
    rho       = get_col_fallback({'Densidad_kg_m3_','Densidad'}, 0.0, e);

    xi = x_pos(ni); yi = y_pos(ni); zi = z_pos(ni); %#ok<NASGU>
    xj = x_pos(nj); yj = y_pos(nj); zj = z_pos(nj); %#ok<NASGU>
    dx = x_pos(nj) - x_pos(ni);
    dy = y_pos(nj) - y_pos(ni);
    dz = z_pos(nj) - z_pos(ni);
    L = sqrt(dx^2 + dy^2 + dz^2);
    if L < 1e-9
        continue;
    end

    EAL = E * A_sec / L;
    GJL = G * J_val / L;
    EIy = E * Iy;
    EIz = E * Iz;

    Kl = zeros(12, 12);
    Kl(1,1) =  EAL; Kl(1,7) = -EAL;
    Kl(7,1) = -EAL; Kl(7,7) =  EAL;
    Kl(4,4) =  GJL; Kl(4,10) = -GJL;
    Kl(10,4) = -GJL; Kl(10,10) =  GJL;

    Ky = flex_block_XY(EIz, L);
    idx_xy = [2, 6, 8, 12];
    Kl(idx_xy, idx_xy) = Kl(idx_xy, idx_xy) + Ky;

    Kz = flex_block_XZ(EIy, L);
    idx_xz = [3, 5, 9, 11];
    Kl(idx_xz, idx_xz) = Kl(idx_xz, idx_xz) + Kz;

    R3  = rotation_matrix_3d(dx, dy, dz, L);
    T12 = make_T12(R3);
    Kg  = T12' * Kl * T12;

    if any(~isfinite(Kg(:)))
        fprintf('    [AVISO] Elemento %d: rigidez no finita - ignorado.\n', elem_id);
        continue;
    end

    dofs_i = (DOF_PER_NODE*(ni-1) + 1) : (DOF_PER_NODE*(ni-1) + DOF_PER_NODE);
    dofs_j = (DOF_PER_NODE*(nj-1) + 1) : (DOF_PER_NODE*(nj-1) + DOF_PER_NODE);
    dofs_e = [dofs_i, dofs_j];

    [idx_C, idx_R] = meshgrid(dofs_e, dofs_e);
    K_row = [K_row; idx_R(:)]; %#ok<AGROW>
    K_col = [K_col; idx_C(:)]; %#ok<AGROW>
    K_data = [K_data; Kg(:)]; %#ok<AGROW>

    n_valid = n_valid + 1;
    elem_info(n_valid).elem_id = elem_id;
    elem_info(n_valid).ni = ni;
    elem_info(n_valid).nj = nj;
    elem_info(n_valid).ni_id = ni_id;
    elem_info(n_valid).nj_id = nj_id;
    elem_info(n_valid).L = L;
    elem_info(n_valid).A_sec = A_sec;
    elem_info(n_valid).E = E;
    elem_info(n_valid).rho = rho;
    elem_info(n_valid).EA = E*A_sec;
    elem_info(n_valid).EIy = EIy;
    elem_info(n_valid).EIz = EIz;
    elem_info(n_valid).Iy = Iy;
    elem_info(n_valid).Iz = Iz;
    elem_info(n_valid).ymax = ymax;
    elem_info(n_valid).zmax = zmax;
    elem_info(n_valid).zp = zp;
    elem_info(n_valid).R3 = R3;
    elem_info(n_valid).T12 = T12;
    elem_info(n_valid).Kl = Kl;
    elem_info(n_valid).dofs_e = dofs_e;
    elem_info(n_valid).zeta = zeta_elem;
    elem_info(n_valid).sigma_y = sigma_y;
    elem_info(n_valid).sigma_u = sigma_u;
end

% ---------------------------------------------------------------
% MASA NODAL ADICIONAL (MasaX/Y/Z del excel) directo a la diagonal
% + inercia rotacional estimada con el radio de giro de los
% elementos conectados a cada nodo (ya NO es el 0.01 fijo de antes,
% ahora se calcula de verdad, gracias por la lección)
% ---------------------------------------------------------------
for i = 1:n_nodes
    base = DOF_PER_NODE*(i-1);
    M_row = [M_row; base+1; base+2; base+3]; %#ok<AGROW>
    M_col = [M_col; base+1; base+2; base+3]; %#ok<AGROW>
    M_data = [M_data; mass_x(i); mass_y(i); mass_z(i)]; %#ok<AGROW>

    ip2_vals = [];
    for ie = 1:n_valid
        if elem_info(ie).ni == i || elem_info(ie).nj == i
            ip2_vals(end+1) = (elem_info(ie).Iy + elem_info(ie).Iz) / (elem_info(ie).A_sec + 1e-20); %#ok<AGROW>
        end
    end
    if ~isempty(ip2_vals)
        ip2 = mean(ip2_vals);
    else
        ip2 = 0.01;
    end
    M_row = [M_row; base+4; base+5; base+6]; %#ok<AGROW>
    M_col = [M_col; base+4; base+5; base+6]; %#ok<AGROW>
    M_data = [M_data; mass_x(i)*ip2; mass_y(i)*ip2; mass_z(i)*ip2]; %#ok<AGROW>
end

% ---------------------------------------------------------------
% MASA CONSISTENTE POR ELEMENTO (rho*A*L), con fallback a masas
% nodales si no hay densidad en el excel (formula EXACTA,
% ojo que NO es 0.5*(mx_i+mx_j) como tenia mi borrador viejo)
% ---------------------------------------------------------------
for ie = 1:n_valid
    ei = elem_info(ie);
    m_elem = ei.rho * ei.A_sec * ei.L;
    if m_elem < 1e-9
        ni_i = ei.ni; nj_i = ei.nj;
        m_elem = 0.5 * (mass_x(ni_i) + mass_x(nj_i) + mass_y(ni_i) + mass_y(nj_i)) / 2.0;
    end
    if m_elem < 1e-15
        continue;
    end
    Ml_c = consistent_mass_12(m_elem, ei.L, ei.A_sec, ei.Iy + ei.Iz);
    Mg_c = ei.T12' * Ml_c * ei.T12;
    dofs_e = ei.dofs_e;
    [idx_C, idx_R] = meshgrid(dofs_e, dofs_e);
    M_row = [M_row; idx_R(:)]; %#ok<AGROW>
    M_col = [M_col; idx_C(:)]; %#ok<AGROW>
    M_data = [M_data; Mg_c(:)]; %#ok<AGROW>
end

K_global = sparse(K_row, K_col, K_data, dof_total, dof_total);
M_global = sparse(M_row, M_col, M_data, dof_total, dof_total);

% Densificamos para el solver de particion,
% (K.toarray() / M.toarray()). Si esto se pone lento con mallas
% grandes, aqui es el primer sospechoso, nota mental, comenzar a correr esto en alguna pc de escritorio.
K = full(K_global);
M = full(M_global);
K(~isfinite(K)) = 0.0;

fprintf('    Elementos proc.  : %d\n', n_valid);
fprintf('    Masa total (x)   : %.4g kg\n', sum(mass_x));

 
%% 5 y 6. CONDICIONES DE CONTORNO Y ANALISIS MODAL
 
fprintf('\n[%s] [PASO 4 y 5/11] Particion Matricial y Analisis Modal ...\n', elapsed());

fixed_dofs_set = false(dof_total, 1);
for i = 1:n_nodes
    base = DOF_PER_NODE*(i-1);
    for d = 1:DOF_PER_NODE
        if fix_flags(i, d) == 1
            fixed_dofs_set(base+d) = true;
        end
    end
end

all_dofs = (1:dof_total)';
free_dofs = all_dofs(~fixed_dofs_set);
n_free = numel(free_dofs);
n_fixed = dof_total - n_free;
fprintf('    DOF restringidos : %d  |  DOF libres: %d\n', n_fixed, n_free);

K_free = K(free_dofs, free_dofs);
M_free = M(free_dofs, free_dofs);
% NOTA: sin perturbacion K += eye*1e-6. Usamos sigma-shift en eigs
% para estabilizar los modos de cuerpo rigido looooool
if USE_SPARSE && n_free > 50
    K_free_sp = sparse(K_free);
    M_free_sp = sparse(M_free);
    k_modes = min(n_free - 2, 200);
    try
        % eigs con sigma=0 == shift-invert alrededor de 0, 
        [V_free, D_eigen] = eigs(K_free_sp, M_free_sp, k_modes, 0);
        eigenvalues = diag(D_eigen);
        eigenvalues = max(eigenvalues, 0.0);
        [eigenvalues, sort_idx] = sort(eigenvalues);
        V_free = V_free(:, sort_idx);
        n_modes = k_modes;
        fprintf('    Solver           : eigs (sparse, sigma-shift) - %d modos\n', k_modes);
    catch ME
        fprintf('    [AVISO] eigs fallo (%s), usando eig dense.\n', ME.message);
        [V_free, D_eigen] = eig(K_free, M_free);
        eigenvalues = max(diag(D_eigen), 0.0);
        [eigenvalues, sort_idx] = sort(eigenvalues);
        V_free = V_free(:, sort_idx);
        n_modes = n_free;
    end
else
    [V_free, D_eigen] = eig(K_free, M_free);
    eigenvalues = max(diag(D_eigen), 0.0);
    [eigenvalues, sort_idx] = sort(eigenvalues);
    V_free = V_free(:, sort_idx);
    n_modes = n_free;
    fprintf('    Solver           : eig (dense)\n');
end

omega_n = sqrt(eigenvalues);
freq_n  = omega_n / (2*pi);

eigenvectors = zeros(dof_total, n_modes);
eigenvectors(free_dofs, :) = V_free;

% ---------------------------------------------------------------
% AMORTIGUAMIENTO MODAL POR ELEMENTO, proyectado al espacio modal:
%   zeta_modal(r) = sum_e( phi_r' * Kg_e * phi_r * zeta_e ) / sum_e(phi_r' * Kg_e * phi_r)
% Ponderado por energia de deformacion modal de cada elemento.
% Esto es NUEVO respecto a mi borrador viejo (que no tenia esto).
% Doble loop modos x elementos, si se pone lento con muchos modos
% y muchos elementos, aqui hay que optimizar (vectorizar Kg_e fuera
% del loop de modos, ya que no depende de r).
% ---------------------------------------------------------------
zeta_modal = zeros(n_modes, 1);
Kg_all = cell(n_valid, 1);
for ie = 1:n_valid
    Kg_all{ie} = elem_info(ie).T12' * elem_info(ie).Kl * elem_info(ie).T12;
end
for r = 1:n_modes
    phi_r = eigenvectors(:, r);
    num = 0.0; den = 0.0;
    for ie = 1:n_valid
        dofs_e = elem_info(ie).dofs_e;
        phi_e = phi_r(dofs_e);
        ke_phi = phi_e' * Kg_all{ie} * phi_e;
        num = num + elem_info(ie).zeta * ke_phi;
        den = den + ke_phi;
    end
    zeta_modal(r) = max(num / (den + 1e-30), DAMPING_MIN);
end

fprintf('    Modos calculados : %d\n', n_modes);
fprintf('    10 primeras frec.: %s Hz\n', mat2str(round(freq_n(1:min(10,n_modes))', 4)));
fprintf('    Zeta modal (modos 1-5): %s\n', mat2str(round(zeta_modal(1:min(5,n_modes))', 4)));

 
%% 7. COMPARACION FRECUENCIAS CALCULADAS vs. REGISTRADAS
 
fprintf('\n[%s] [PASO 6/11] Comparando frecuencias calc. vs. medidas ...\n', elapsed());

amp_threshold = 0.10 * max(amp_N_input);
% findpeaks de matlab es increible, gracias Dios por el creador de
% findpeaks SI NO ERES EL CREADOR RECUERDA INSTALAR EL "Signal Proccessing
% Toolbox", porque si no peta.
[amp_measured_peaks, peaks_idx] = findpeaks(amp_N_input, ...
    'MinPeakHeight', amp_threshold, ...
    'MinPeakDistance', 100, ...
    'MinPeakProminence', amp_threshold * 0.2);
freq_measured_peaks = freq_hz_input(peaks_idx);

freq_calc_valid = freq_n(freq_n >= 0.1);
comparison_rows = struct('f_medida_Hz', {}, 'Amp_medida_m', {}, 'f_calculada_Hz', {}, 'Error_pct', {});
for k = 1:numel(freq_measured_peaks)
    if isempty(freq_calc_valid)
        break;
    end
    f_meas = freq_measured_peaks(k);
    amp_meas = amp_measured_peaks(k);
    diffs = abs(freq_calc_valid - f_meas);
    [~, best_idx] = min(diffs);
    f_calc = freq_calc_valid(best_idx);
    err_pct = abs(f_calc - f_meas) / (f_meas + 1e-12) * 100.0;
    comparison_rows(end+1) = struct( ...
        'f_medida_Hz', round(f_meas, 4), ...
        'Amp_medida_m', round(amp_meas, 6), ...
        'f_calculada_Hz', round(f_calc, 4), ...
        'Error_pct', round(err_pct, 2)); %#ok<SAGROW>
end

if ~isempty(comparison_rows)
    df_cmp = struct2table(comparison_rows);
    fprintf('    Picos medidos : %d\n', numel(freq_measured_peaks));
    disp(df_cmp(1:min(20,height(df_cmp)), :));
else
    df_cmp = table();
    fprintf('    No se encontraron picos sobre el umbral del 10%%.\n');
end

 
%% 8. RESPUESTA DINAMICA (superposicion modal)
 
fprintf('\n[%s] [PASO 7/11] Calculando respuesta dinamica ...\n', elapsed());

omega_eval   = omega_input;
amp_N_eval   = amp_N_input; %#ok<NASGU>
freq_hz_eval = freq_hz_input; %#ok<NASGU>
fprintf('    Espectro procesado: %d puntos (barrido completo)\n', numel(omega_eval));

% interp1 con clamp en los bordes. Aqui
% omega_eval == omega_input asi que en la practica es identidad, pero
% lo dejamos generico por si el dia de mañana cambian. ES UN DOLOR DE CABEZA LIDIAR CON ESTO MANUALMENTE.
omega_eval_clamped = min(max(omega_eval, omega_input(1)), omega_input(end));
amp_in_eval = interp1(omega_input, amp_N_input, omega_eval_clamped, 'linear');

n_freq = numel(omega_eval);
U_dof_complex = zeros(n_freq, dof_total);

% Carga unitaria en el primer DOF traslacional (X) de CADA nodo,
% no solo del nodo 1 como en mi borrador viejo. Ojo con esto.
f_vec = zeros(dof_total, 1);
for i = 1:n_nodes
    f_vec(DOF_PER_NODE*(i-1) + 1) = 1.0;
end

for r = 1:n_modes
    phi = eigenvectors(:, r);
    wn  = omega_n(r);
    z   = zeta_modal(r);
    m_r = phi' * M * phi;
    if m_r < 1e-15 || wn < 1e-3
        continue;
    end

    if IS_FORCE_INPUT
        gamma_r = (phi' * f_vec) / m_r;
    else
        % gamma_r inercial para excitacion de base: F_eff = M*phi
        gamma_r = (phi' * M * f_vec) / m_r;
    end

    wn2 = wn^2;
    beta = omega_eval / (wn + 1e-30);
    den = (1.0 - beta.^2) + 1i*(2.0*z*beta);
    H_r = 1.0 ./ den;

    if IS_FORCE_INPUT
        q_r = gamma_r * amp_in_eval .* H_r / (wn2 + 1e-30);
    else
        q_r = gamma_r * amp_in_eval .* (omega_eval.^2) .* H_r / (wn2 + 1e-30);
    end

    U_dof_complex = U_dof_complex + q_r * phi';   % outer product (n_freq x dof_total)
end

 
%% 8b. RESPUESTA AL ESCALON -- OMITIDA A PROPOSITO
 
%Si algun dia se necesita el escalon de verdad, aqui es
% donde se agregaria.
U_dof = abs(U_dof_complex);

U_node = zeros(n_freq, n_nodes);
for i = 1:n_nodes
    b = DOF_PER_NODE*(i-1);
    U_node(:, i) = sqrt(U_dof(:,b+1).^2 + U_dof(:,b+2).^2 + U_dof(:,b+3).^2);
end

fprintf('    Respuesta calculada para %d modos.\n', n_modes);

 
%% 8. ESTRES VON MISES + FACTORES FS y FU (Dinamico + Gravedad)
 
fprintf('\n[%s] [PASO 8/11] Calculando sigma_vm (Gravedad + Dinamico) + FS + FU ...\n', elapsed());

% --- 8.1 Deformacion estatica por gravedad ---
F_grav = zeros(dof_total, 1);
for i = 1:n_nodes
    F_grav(DOF_PER_NODE*(i-1) + 3) = -mass_z(i) * GRAVITY;
end
F_grav_free = F_grav(free_dofs);
% backslash de matlab ya hace lstsq si K_free es singular/mal condicionada,
% pero por si las dudas dejamos el try/catch como en el
try
    u_grav_free = K_free \ F_grav_free;
catch
    u_grav_free = lsqminnorm(K_free, F_grav_free);
end
u_grav_full = zeros(dof_total, 1);
u_grav_full(free_dofs) = u_grav_free;

% --- 8.2 Calculos por elemento ---
n_elem = n_valid;
elem_stress_max_Pa  = zeros(n_elem, 1);
elem_stress_max_MPa = zeros(n_elem, 1);
elem_sf = nan(n_elem, 1);
elem_uf = nan(n_elem, 1);
elem_strain_max = zeros(n_elem, 1);
node_stress_MPa = zeros(n_nodes, 1);

sigma_y_vals = [elem_info.sigma_y]';
sigma_u_vals = [elem_info.sigma_u]';
n_sin_limite = sum(isinf(sigma_y_vals) & isinf(sigma_u_vals));
if n_sin_limite > 0
    fprintf('    [AVISO] %d elementos sin Sigma_y ni Sigma_u -> FS/FU = N/A\n', n_sin_limite);
else
    finitos_y = sigma_y_vals(isfinite(sigma_y_vals));
    if ~isempty(finitos_y)
        fprintf('    Sigma_y [Pa]     : min=%.3e  max=%.3e\n', min(finitos_y), max(finitos_y));
    end
end

for ie = 1:n_elem
    ei = elem_info(ie);
    dofs_e = ei.dofs_e;
    L   = ei.L;
    Kl  = ei.Kl;
    T12 = ei.T12;

    % ---- 1. Fuerzas estaticas (gravedad) ----
    u_e_grav_global = u_grav_full(dofs_e);
    u_e_grav_local  = T12 * u_e_grav_global;
    F_grav_local    = Kl * u_e_grav_local;

    N_grav  = max(abs(F_grav_local(1)), abs(F_grav_local(7)));
    My_grav = max(abs(F_grav_local(5)), abs(F_grav_local(11)));
    Mz_grav = max(abs(F_grav_local(6)), abs(F_grav_local(12)));
    T_grav  = max(abs(F_grav_local(4)), abs(F_grav_local(10)));

    % ---- 2. Fuerzas dinamicas (espectro completo) ----
    U_e_global = U_dof_complex(:, dofs_e);         % n_freq x 12
    U_e_local  = U_e_global * T12';                % n_freq x 12

    delta_L = U_e_local(:,7) - U_e_local(:,1);
    delta_L_max = max(abs(delta_L));
    epsilon_max = delta_L_max / L;
    elem_strain_max(ie) = epsilon_max;

    F_local_cplx = (Kl * U_e_local')';             % n_freq x 12
    F_local_amp  = abs(F_local_cplx);

    N_dyn  = max(max(F_local_amp(:,1),  F_local_amp(:,7)));
    My_dyn = max(max(F_local_amp(:,5),  F_local_amp(:,11)));
    Mz_dyn = max(max(F_local_amp(:,6),  F_local_amp(:,12)));
    T_dyn  = max(max(F_local_amp(:,4),  F_local_amp(:,10)));

    % ---- 3. Superposicion total (peor caso: gravedad + dinamica) ----
    N_max  = N_grav + N_dyn;
    My_max = My_grav + My_dyn;
    Mz_max = Mz_grav + Mz_dyn;
    T_max  = T_grav + T_dyn;

    A_sec = ei.A_sec; Iy = ei.Iy; Iz = ei.Iz;
    ymax = ei.ymax; zmax = ei.zmax; zp = ei.zp;

    sigma_axial  = 0.0; if A_sec > 0, sigma_axial = N_max / A_sec; end
    sigma_bend_y = 0.0; if (Iy > 0 && zmax > 0), sigma_bend_y = My_max * zmax / Iy; end
    sigma_bend_z = 0.0; if (Iz > 0 && ymax > 0), sigma_bend_z = Mz_max * ymax / Iz; end
    sigma_x = abs(sigma_axial) + abs(sigma_bend_y) + abs(sigma_bend_z);
    tau_t = 0.0; if zp > 0, tau_t = T_max / zp; end

    sigma_vm_Pa = sqrt(sigma_x^2 + 3.0*tau_t^2);

    elem_stress_max_Pa(ie)  = sigma_vm_Pa;
    elem_stress_max_MPa(ie) = sigma_vm_Pa / 1e6;

    if isfinite(ei.sigma_y)
        sigma_lim = ei.sigma_y;
    else
        sigma_lim = ei.sigma_u;
    end
    if isfinite(sigma_lim) && sigma_lim > 0
        elem_uf(ie) = sigma_vm_Pa / sigma_lim;
        if sigma_vm_Pa > 1e-9
            elem_sf(ie) = sigma_lim / sigma_vm_Pa;
        else
            elem_sf(ie) = Inf;
        end
    end

    elem_info(ie).fu = elem_uf(ie);
    elem_info(ie).fs = elem_sf(ie);
    elem_info(ie).fail_y = sigma_vm_Pa >= ei.sigma_y;
    elem_info(ie).fail_u = sigma_vm_Pa >= ei.sigma_u;

    ni = ei.ni; nj = ei.nj;
    node_stress_MPa(ni) = max(node_stress_MPa(ni), elem_stress_max_MPa(ie));
    node_stress_MPa(nj) = max(node_stress_MPa(nj), elem_stress_max_MPa(ie));
end

[max_stress, idx_max_stress] = max(elem_stress_max_MPa);
fprintf('    sigma_vm max [MPa]   : %.6f  (elem %d)\n', max_stress, elem_info(idx_max_stress).elem_id);
fprintf('    eps_max [uE]         : %.4f\n', max(elem_strain_max)*1e6);

 
%% 9. FACTOR DLF E INDICE DE RESONANCIA
 
fprintf('\n[%s] [PASO 9/11] Calculando DLF e Indice de Resonancia ...\n', elapsed());

% --- Respuesta estatica unitaria (para el indice DLF) ---
if IS_FORCE_INPUT
    F_st_unit = f_vec;
else
    F_st_unit = M * f_vec;
end
F_st_free = F_st_unit(free_dofs);
try
    u_st_free = K_free \ F_st_free;
catch
    u_st_free = lsqminnorm(K_free, F_st_free);
end
u_st_full = zeros(dof_total, 1);
u_st_full(free_dofs) = u_st_free;

u_st_node = zeros(n_nodes, 1);
for i = 1:n_nodes
    b = DOF_PER_NODE*(i-1);
    u_st_node(i) = sqrt(u_st_full(b+1)^2 + u_st_full(b+2)^2 + u_st_full(b+3)^2);
end

% Frecuencia de excitacion dominante (donde el espectro de entrada tiene
% mayor energia). Solo se usa para el resumen final -- el calculo de
% beta usa dlf_freq_per_node (mas representativo, por nodo).
[~, idx_dom] = max(amp_in_eval);
f_excit_dominante = freq_hz_eval(idx_dom);

if IS_FORCE_INPUT
    F_in_max = max(amp_in_eval);
else
    F_in_max = max(amp_in_eval .* (omega_eval.^2));
end
u_st_eq_max = u_st_node * F_in_max; %#ok<NASGU> % no se usa despues
U_max_node = max(U_node, [], 1)';

DLF_node = zeros(n_nodes, 1);
peak_freq_per_node = zeros(n_nodes, 1);
dlf_freq_per_node  = zeros(n_nodes, 1);
resonance_beta     = zeros(n_nodes, 1);

valid_f_n = freq_n(freq_n > 0.01);  % modos rigidos excluidos

if ~isempty(zeta_modal) && min(zeta_modal) > 0
    max_DLF_teorico = 1.0 / (2.0 * min(zeta_modal));
else
    max_DLF_teorico = Inf;
end

for i = 1:n_nodes
    u_i = U_node(:, i);
    if IS_FORCE_INPUT
        u_st_w = u_st_node(i) * amp_in_eval;
    else
        u_st_w = u_st_node(i) * amp_in_eval .* (omega_eval.^2);
    end
    ratio = zeros(size(u_i));
    mask_ok = u_st_w > 1e-15;
    ratio(mask_ok) = u_i(mask_ok) ./ u_st_w(mask_ok);
    [ratio_max, idx_ratio_max] = max(ratio);
    DLF_node(i) = min(ratio_max, max_DLF_teorico);
    dlf_freq_per_node(i) = freq_hz_eval(idx_ratio_max);

    % Pico de respuesta real del nodo (no el pico global por omega)
    if max(u_i) > 1e-15
        [pk_vals, pk_locs] = findpeaks(u_i, 'MinPeakProminence', max(u_i)*0.05);
        if ~isempty(pk_locs)
            [~, i_best] = max(pk_vals);
            peak_freq_per_node(i) = freq_hz_eval(pk_locs(i_best));
        else
            [~, idx_max_u] = max(u_i);
            peak_freq_per_node(i) = freq_hz_eval(idx_max_u);
        end
    else
        peak_freq_per_node(i) = 0.0;
    end

    if max(u_i) < 1e-12
        resonance_beta(i) = 0.0;
    elseif ~isempty(valid_f_n)
        f_exc_nodo = dlf_freq_per_node(i);
        [~, idx_closest] = min(abs(valid_f_n - f_exc_nodo));
        f_n_closest = valid_f_n(idx_closest);
        if f_n_closest > 1e-6
            resonance_beta(i) = f_exc_nodo / f_n_closest;
        else
            resonance_beta(i) = 0.0;
        end
    end
end

n_resonantes = sum(resonance_beta > 0.85 & resonance_beta < 1.15);
[~, idx_dlf_max]  = max(DLF_node);
[~, idx_beta_max] = max(resonance_beta);
fprintf('    DLF maximo       : %.4f  (nodo %d)\n', max(DLF_node), node_ids(idx_dlf_max));
fprintf('    Beta max (RI)    : %.4f  (nodo %d)\n', max(resonance_beta), node_ids(idx_beta_max));
fprintf('    Nodos en riesgo  : %d (0.85 < beta < 1.15)\n', n_resonantes);
fprintf('    [NOTA] Beta mide f_excitacion_nodo / f_natural_mas_cercana.\n');
fprintf('           Beta=1 => la carga actua exactamente en un modo natural.\n');

 
%% 9b. FORMAS MODALES (modos normales)
 
fprintf('\n[%s] [PASO 9b] Graficando formas modales (modos normales) ...\n', elapsed());

N_MODES_PLOT = min(6, n_modes);
rango_geom = max([max(x_pos)-min(x_pos), max(y_pos)-min(y_pos), max(max(z_pos)-min(z_pos), 1e-6)]);

if GRAF('Modos_Normales')
    for r = 1:N_MODES_PLOT
        phi = eigenvectors(:, r);
        disp_tr = zeros(n_nodes,1);
        for i = 1:n_nodes
            b = DOF_PER_NODE*(i-1);
            disp_tr(i) = sqrt(phi(b+1)^2 + phi(b+2)^2 + phi(b+3)^2);
        end
        max_disp = max(disp_tr); if max_disp < 1e-12, max_disp = 1.0; end
        scale = rango_geom * 0.05 / max_disp;

        x_def = x_pos + phi(1:DOF_PER_NODE:end) * scale;
        y_def = y_pos + phi(2:DOF_PER_NODE:end) * scale;
        z_def = z_pos + phi(3:DOF_PER_NODE:end) * scale;

        stress_modal_arr = zeros(n_valid,1);
        for k = 1:n_valid
            stress_modal_arr(k) = von_mises_elem(elem_info(k), phi);
        end
        vmax_m = max(stress_modal_arr); if vmax_m <= 0, vmax_m = 1e-12; end

        fig_m = figure('Visible','off','Position',[100 100 1000 700]);
        if use_3d_plot
            ax_m = axes(fig_m); hold(ax_m,'on'); view(ax_m,3);
        else
            ax_m = axes(fig_m); hold(ax_m,'on'); axis(ax_m,'equal');
        end
        for k = 1:n_valid
            ei = elem_info(k); ni = ei.ni; nj = ei.nj;
            color_rel = cmap_stress(stress_modal_arr(k)/vmax_m);
            if use_3d_plot
                plot3(ax_m,[x_pos(ni),x_pos(nj)],[y_pos(ni),y_pos(nj)],[z_pos(ni),z_pos(nj)], ...
                    '--','Color',[0 0 1],'LineWidth',1);
                plot3(ax_m,[x_def(ni),x_def(nj)],[y_def(ni),y_def(nj)],[z_def(ni),z_def(nj)], ...
                    'Color',color_rel,'LineWidth',2.5);
            else
                plot(ax_m,[x_pos(ni),x_pos(nj)],[y_pos(ni),y_pos(nj)], '--','Color',[0 0 1],'LineWidth',1);
                plot(ax_m,[x_def(ni),x_def(nj)],[y_def(ni),y_def(nj)], 'Color',color_rel,'LineWidth',2.5);
            end
        end
        colormap(ax_m, cmap_stress_array(256));
        caxis(ax_m, [0, vmax_m]);
        cb_m = colorbar(ax_m); cb_m.Label.String = 'sigma_vm de Forma Modal (Relativo)';
        xlabel(ax_m,'X [m]'); ylabel(ax_m,'Y [m]'); if use_3d_plot, zlabel(ax_m,'Z [m]'); end
        if ~use_3d_plot, grid(ax_m,'on'); ax_m.GridAlpha=0.3; ax_m.GridLineStyle='--'; end

        txt_params = sprintf('Exageracion Visual de Forma: %.1fx\nEstres VM Relativo: %.4f', scale, vmax_m);
        text(ax_m, 0.98, 0.98, txt_params, 'Units','normalized', 'HorizontalAlignment','right', ...
             'VerticalAlignment','top', 'FontSize',8, 'FontWeight','bold', ...
             'BackgroundColor',[1 1 1], 'EdgeColor',[0.81 0.85 0.86]);
        title(ax_m, sprintf('Modo Normal %d  --  f = %.4f Hz', r, freq_n(r)), 'FontWeight','bold');

        if use_3d_plot
            h_orig = plot3(ax_m, nan, nan, nan, '--', 'Color',[0 0 1], 'LineWidth',1);
            h_def  = plot3(ax_m, nan, nan, nan, 'Color',[1.0 0.435 0.0], 'LineWidth',2.5);
        else
            h_orig = plot(ax_m, nan, nan, '--', 'Color',[0 0 1], 'LineWidth',1);
            h_def  = plot(ax_m, nan, nan, 'Color',[1.0 0.435 0.0], 'LineWidth',2.5);
        end
        legend(ax_m, [h_orig, h_def], {'Geometria original','Forma deformada (Calentamiento rel.)'}, ...
               'FontSize',9, 'Location','best');

        fname = sprintf('modo_%02d_f%.3fHz.png', r, freq_n(r));
        save_fig_safe(fig_m, fullfile(MODAL_DIR, fname), true);
    end
    fprintf('    %d modos normales guardados en ''%s''\n', N_MODES_PLOT, MODAL_DIR);
else
    fprintf('    Modos normales: omitidos (Graficas=n)\n');
end

 
%% 10. GRAFICACION (figuras estaticas + espectros por nodo)
 
fprintf('\n[%s] [PASO 10/11] Generando figuras ...\n', elapsed());

vmax_e = max(elem_stress_max_MPa); if isempty(vmax_e), vmax_e = 1.0; end
vmin_e = min(elem_stress_max_MPa); if isempty(vmin_e), vmin_e = 0.0; end
norm_s = @(v) (v - vmin_e) / (vmax_e - vmin_e + 1e-12);

elem_ids_plot = [elem_info.elem_id]';
node_id_labels = arrayfun(@(x) num2str(x), node_ids, 'UniformOutput', false);
elem_id_labels = arrayfun(@(x) num2str(x), elem_ids_plot, 'UniformOutput', false);

% ---- fig1: Mapa de calor de estres --------------------------------
p90_stress = prctile(node_stress_MPa, 90);
crit_nodes = find(node_stress_MPa >= p90_stress);
is_crit = false(n_nodes,1); is_crit(crit_nodes) = true;

fig1 = figure('Visible','off','Position',[100 100 1300 800]);
if use_3d_plot
    ax1 = axes(fig1); hold(ax1,'on'); view(ax1,3);
else
    ax1 = axes(fig1); hold(ax1,'on'); axis(ax1,'equal');
end
for ie = 1:n_elem
    ei = elem_info(ie); ni = ei.ni; nj = ei.nj;
    col = cmap_stress(norm_s(elem_stress_max_MPa(ie)));
    if use_3d_plot
        plot3(ax1, [x_pos(ni),x_pos(nj)], [y_pos(ni),y_pos(nj)], [z_pos(ni),z_pos(nj)], 'Color',col,'LineWidth',2.5);
    else
        plot(ax1, [x_pos(ni),x_pos(nj)], [y_pos(ni),y_pos(nj)], 'Color',col,'LineWidth',3);
    end
end
for i = 1:n_nodes
    if is_crit(i), c = [0.827 0.184 0.184]; s = 45; else, c = [0.271 0.353 0.392]; s = 20; end
    if use_3d_plot
        scatter3(ax1, x_pos(i), y_pos(i), z_pos(i), s, c, 'filled');
        text(ax1, x_pos(i), y_pos(i), z_pos(i), node_id_labels{i}, 'FontSize',7);
    else
        scatter(ax1, x_pos(i), y_pos(i), s, c, 'filled');
        text(ax1, x_pos(i), y_pos(i), node_id_labels{i}, 'FontSize',7);
    end
end
colormap(ax1, cmap_stress_array(256));
caxis(ax1, [vmin_e, vmax_e + 1e-12]);
cb1 = colorbar(ax1); cb1.Label.String = 'sigma_vm [MPa]';
title(ax1, {'Mapa de Calor -- sigma\_vm Von Mises por Elemento', ...
    '(Nodos en rojo son puntos criticos = Top 10% mayor estres)'}, 'FontWeight','bold');
xlabel(ax1,'x [m]'); ylabel(ax1,'y [m]'); if use_3d_plot, zlabel(ax1,'z [m]'); end
if ~use_3d_plot, grid(ax1,'on'); ax1.GridAlpha=0.3; ax1.GridLineStyle='--'; end
save_fig_safe(fig1, fullfile(GRAFICAS_DIR,'Mapa_Estres_Calor.png'), GRAF('Mapa_Estres'));

% ---- fig2: estres por elemento (barras) ---------------------------
fig2 = figure('Visible','off','Position',[100 100 1400 500]);
ax2 = axes(fig2);
bar_colors2 = zeros(n_elem,3);
for ie = 1:n_elem, bar_colors2(ie,:) = cmap_stress(norm_s(elem_stress_max_MPa(ie))); end
b2 = bar(ax2, 1:n_elem, elem_stress_max_MPa, 0.7, 'FaceColor','flat','EdgeColor','k','LineWidth',0.5);
b2.CData = bar_colors2;
set(ax2, 'XTick', 1:n_elem, 'XTickLabel', elem_id_labels, 'XTickLabelRotation', 60);
xlabel(ax2,'Elemento'); ylabel(ax2,'sigma_vm [MPa]');
title(ax2, 'sigma_vm Von Mises Maximo por Elemento [MPa]', 'FontWeight','bold');
grid(ax2,'on'); ylim(ax2,[0, max(elem_stress_max_MPa)*1.05+eps]);
save_fig_safe(fig2, fullfile(GRAFICAS_DIR,'Mapa_Estres_Barras.png'), GRAF('Mapa_Estres'));

% ---- fig1b: deformacion epsilon ------------------------------------
fig1b = figure('Visible','off','Position',[100 100 1200 500]);
ax1b = axes(fig1b);
bar(ax1b, 1:n_elem, elem_strain_max*1e6, 'FaceColor',[0.557 0.141 0.667],'EdgeColor','k','LineWidth',0.5,'FaceAlpha',0.85);
set(ax1b,'XTick',1:n_elem,'XTickLabel',elem_id_labels,'XTickLabelRotation',60);
xlabel(ax1b,'Elemento'); ylabel(ax1b,'Deformacion Epsilon [uE]');
title(ax1b,'Deformacion Epsilon Maxima por Elemento [uE]','FontWeight','bold');
grid(ax1b,'on'); ylim(ax1b,[0, max(elem_strain_max*1e6)*1.05+eps]);
save_fig_safe(fig1b, fullfile(GRAFICAS_DIR,'Mapa_Deformacion.png'), GRAF('Mapa_Deformacion'));

% ---- fig_fs: Factor de Seguridad ------------------------------------
fig_fs = figure('Visible','off','Position',[100 100 1400 500]);
ax_fs = axes(fig_fs); hold(ax_fs,'on');
fs_for_bar = zeros(n_elem,1); fs_colors = zeros(n_elem,3);
for ie = 1:n_elem
    fs_v = elem_sf(ie);
    if ~isfinite(fs_v) || fs_v <= 0
        fs_for_bar(ie) = 0; fs_colors(ie,:) = [0.690 0.745 0.773];
    else
        fs_for_bar(ie) = min(fs_v, 10.0);
        if fs_v <= 1.0,     fs_colors(ie,:) = [0.937 0.325 0.314];
        elseif fs_v <= 1.5, fs_colors(ie,:) = [1.0 0.651 0.149];
        else,               fs_colors(ie,:) = [0.298 0.686 0.314];
        end
    end
end
b_fs = bar(ax_fs, 1:n_elem, fs_for_bar, 'FaceColor','flat','EdgeColor','k','LineWidth',0.5);
b_fs.CData = fs_colors;
yline(ax_fs, 1.0, '--', 'Color',[1 0 0], 'LineWidth',1.4);
yline(ax_fs, 1.5, ':',  'Color',[1 0.5 0], 'LineWidth',1.0);
set(ax_fs,'XTick',1:n_elem,'XTickLabel',elem_id_labels,'XTickLabelRotation',60);
xlabel(ax_fs,'Elemento'); ylabel(ax_fs,'FS = sigma_limite / sigma_vm  (cap. 10)');
title(ax_fs,'Factor de Seguridad por Elemento  FS = sigma_limite / sigma_vm  (cap. 10)','FontWeight','bold');
grid(ax_fs,'on'); ylim(ax_fs,[0, 10.5]);
h_leg_fs = [patch(ax_fs,nan,nan,[0.937 0.325 0.314]), patch(ax_fs,nan,nan,[1.0 0.651 0.149]), ...
            patch(ax_fs,nan,nan,[0.298 0.686 0.314]), patch(ax_fs,nan,nan,[0.690 0.745 0.773])];
legend(h_leg_fs, {'FS <= 1.0 (Falla)','1.0 < FS <= 1.5 (Alerta)','FS > 1.5 (OK)','Sin datos (N/A)'}, ...
       'FontSize',8, 'Location','northeast');
save_fig_safe(fig_fs, fullfile(GRAFICAS_DIR,'FS_Elementos.png'), GRAF('FS_Elementos'));

% ---- fig_uf: Factor de Utilizacion ----------------------------------
fig_uf = figure('Visible','off','Position',[100 100 1400 500]);
ax_uf = axes(fig_uf); hold(ax_uf,'on');
fu_for_bar = zeros(n_elem,1); fu_colors = zeros(n_elem,3);
for ie = 1:n_elem
    fu_v = elem_uf(ie);
    if ~isfinite(fu_v)
        fu_for_bar(ie) = 0; fu_colors(ie,:) = [0.690 0.745 0.773];
    else
        fu_for_bar(ie) = fu_v;
        if fu_v >= 1.0,     fu_colors(ie,:) = [0.937 0.325 0.314];
        elseif fu_v >= 0.8, fu_colors(ie,:) = [1.0 0.651 0.149];
        else,               fu_colors(ie,:) = [0.129 0.588 0.953];
        end
    end
end
b_uf = bar(ax_uf, 1:n_elem, fu_for_bar, 'FaceColor','flat','EdgeColor','k','LineWidth',0.5);
b_uf.CData = fu_colors;
yline(ax_uf, 1.0, '--', 'Color',[1 0 0], 'LineWidth',1.4);
yline(ax_uf, 0.8, ':',  'Color',[1 0.5 0], 'LineWidth',1.0);
set(ax_uf,'XTick',1:n_elem,'XTickLabel',elem_id_labels,'XTickLabelRotation',60);
xlabel(ax_uf,'Elemento'); ylabel(ax_uf,'FU = sigma_vm / sigma_limite');
title(ax_uf,'Factor de Utilizacion por Elemento  FU = sigma_vm / sigma_limite','FontWeight','bold');
grid(ax_uf,'on'); ylim(ax_uf,[0, max([fu_for_bar; 1.1])]);
h_leg_uf = [patch(ax_uf,nan,nan,[0.937 0.325 0.314]), patch(ax_uf,nan,nan,[1.0 0.651 0.149]), ...
            patch(ax_uf,nan,nan,[0.129 0.588 0.953]), patch(ax_uf,nan,nan,[0.690 0.745 0.773])];
legend(h_leg_uf, {'FU >= 1.0 (Falla)','0.8 <= FU < 1.0 (Alerta)','FU < 0.8 (OK)','Sin datos (N/A)'}, ...
       'FontSize',8, 'Location','northeast');
save_fig_safe(fig_uf, fullfile(GRAFICAS_DIR,'FU_Elementos.png'), GRAF('FU_Elementos'));

% ---- fig1c: mapa de referencia de elementos -------------------------
fig1c = figure('Visible','off','Position',[100 100 1600 1200]);
if use_3d_plot
    ax1c = axes(fig1c); hold(ax1c,'on'); view(ax1c,3);
else
    ax1c = axes(fig1c); hold(ax1c,'on'); axis(ax1c,'equal');
end
for ie = 1:n_elem
    ei = elem_info(ie); ni = ei.ni; nj = ei.nj;
    mx=(x_pos(ni)+x_pos(nj))/2; my=(y_pos(ni)+y_pos(nj))/2; mz=(z_pos(ni)+z_pos(nj))/2;
    if use_3d_plot
        plot3(ax1c, [x_pos(ni),x_pos(nj)], [y_pos(ni),y_pos(nj)], [z_pos(ni),z_pos(nj)], 'Color',[0.690 0.745 0.773],'LineWidth',2);
        text(ax1c, mx,my,mz, num2str(ei.elem_id), 'Color',[0.290 0.078 0.549],'FontSize',11,'FontWeight','bold','HorizontalAlignment','center');
    else
        plot(ax1c, [x_pos(ni),x_pos(nj)], [y_pos(ni),y_pos(nj)], 'Color',[0.690 0.745 0.773],'LineWidth',2);
        text(ax1c, mx,my, num2str(ei.elem_id), 'Color',[0.290 0.078 0.549],'FontSize',11,'FontWeight','bold','HorizontalAlignment','center');
    end
end
if use_3d_plot
    scatter3(ax1c, x_pos, y_pos, z_pos, 30, [0.329 0.431 0.478],'filled');
    max_r = max([max(x_pos)-min(x_pos), max(y_pos)-min(y_pos), max(z_pos)-min(z_pos)]);
    cx=(max(x_pos)+min(x_pos))/2; cy=(max(y_pos)+min(y_pos))/2; cz=(max(z_pos)+min(z_pos))/2;
    xlim(ax1c,[cx-max_r*0.5, cx+max_r*0.5]); ylim(ax1c,[cy-max_r*0.5, cy+max_r*0.5]); zlim(ax1c,[cz-max_r*0.5, cz+max_r*0.5]);
    xlabel(ax1c,'x [m]'); ylabel(ax1c,'y [m]'); zlabel(ax1c,'z [m]');
else
    scatter(ax1c, x_pos, y_pos, 30, [0.329 0.431 0.478],'filled');
    xlabel(ax1c,'x [m]'); ylabel(ax1c,'y [m]'); grid(ax1c,'on'); ax1c.GridAlpha=0.3; ax1c.GridLineStyle='--';
end
title(ax1c, 'Esquema de Referencia: Numeracion de Elementos', 'FontSize',14,'FontWeight','bold');
save_fig_safe(fig1c, fullfile(GRAFICAS_DIR,'Mapa_Elementos.png'), GRAF('Mapa_Elementos'));

% ---- fig3a: Factor DLF por nodo -------------------------------------
fig3a = figure('Visible','off','Position',[100 100 1400 500]);
ax3a = axes(fig3a); hold(ax3a,'on');
dlf_norm = DLF_node / (max(DLF_node) + 1e-15);
dlf_colors = zeros(n_nodes,3);
for i=1:n_nodes, dlf_colors(i,:) = cmap_stress(dlf_norm(i)); end
b3a = bar(ax3a, 1:n_nodes, DLF_node, 0.7, 'FaceColor','flat','EdgeColor','k','LineWidth',0.5);
b3a.CData = dlf_colors;
if isfinite(max_DLF_teorico)
    yline(ax3a, max_DLF_teorico, '--', sprintf('DLF Max. Teorico (%.2f)', max_DLF_teorico), 'Color','r','LineWidth',1.5);
end
set(ax3a,'XTick',1:n_nodes,'XTickLabel',node_id_labels,'XTickLabelRotation',60);
xlabel(ax3a,'Nodo'); ylabel(ax3a,'Factor Dinamico de Carga (DLF) = U_din / U_est');
title(ax3a, {'Factor de Amplificacion Dinamica (DLF) por Nodo', 'DLF = max_w [ U_din(w) / (u_st * F(w)) ]'}, 'FontWeight','bold');
grid(ax3a,'on'); ylim(ax3a,[0, max(DLF_node)*1.1+eps]);
save_fig_safe(fig3a, fullfile(GRAFICAS_DIR,'Factor_DLF.png'), GRAF('Factor_DLF'));

% ---- fig3b: Indice de Resonancia Beta --------------------------------
fig3b = figure('Visible','off','Position',[100 100 1400 500]);
ax3b = axes(fig3b); hold(ax3b,'on');
beta_norm = resonance_beta / (max(resonance_beta) + 1e-15);
beta_colors = zeros(n_nodes,3);
for i=1:n_nodes, beta_colors(i,:) = cmap_stress(beta_norm(i)); end
b3b = bar(ax3b, 1:n_nodes, resonance_beta, 0.7, 'FaceColor','flat','EdgeColor','k','LineWidth',0.5);
b3b.CData = beta_colors;
yline(ax3b, 1.0,  '--', 'Beta = 1 (Resonancia ideal)', 'Color','r','LineWidth',1.2);
yline(ax3b, 0.8,  ':',  'Color',[1 0.5 0], 'LineWidth',1.0);
yline(ax3b, 1.25, ':',  'Color',[1 0.5 0], 'LineWidth',1.0);
set(ax3b,'XTick',1:n_nodes,'XTickLabel',node_id_labels,'XTickLabelRotation',60);
xlabel(ax3b,'Nodo'); ylabel(ax3b,'Indice de Resonancia beta = w_act / w_n');
title(ax3b, {'Indice de Resonancia (beta) por Nodo', 'beta = Freq_pico_actuante / Freq_natural_mas_cercana'}, 'FontWeight','bold');
grid(ax3b,'on'); ylim(ax3b,[0, max(resonance_beta)*1.1+eps]);
save_fig_safe(fig3b, fullfile(GRAFICAS_DIR,'Resonancia_beta.png'), GRAF('Resonancia_beta'));

% ---- fig3c: Frecuencia pico por nodo ---------------------------------
fig3c = figure('Visible','off','Position',[100 100 1400 500]);
ax3c = axes(fig3c); hold(ax3c,'on');
plot(ax3c, 1:n_nodes, peak_freq_per_node, '--', 'Color',[1.0 0.341 0.133]);
scatter(ax3c, 1:n_nodes, peak_freq_per_node, 60, [1.0 0.341 0.133], 'filled','MarkerEdgeColor','k');
set(ax3c,'XTick',1:n_nodes,'XTickLabel',node_id_labels,'XTickLabelRotation',60);
xlabel(ax3c,'Nodo'); ylabel(ax3c,'Frecuencia pico [Hz]');
title(ax3c,'Frecuencia Pico (Mayor Desplazamiento) por Nodo','FontWeight','bold');
grid(ax3c,'on'); ax3c.GridAlpha=0.3; ax3c.GridLineStyle='--'; ylim(ax3c,[0, max(peak_freq_per_node)*1.1+eps]);
save_fig_safe(fig3c, fullfile(GRAFICAS_DIR,'Frecuencia_Pico.png'), GRAF('Frecuencia_Pico'));

% ---- fig4: espectro global + respuesta + lineas de resonancia -------
fig4 = figure('Visible','off','Position',[100 100 1600 600]);
ax4 = axes(fig4); hold(ax4,'on');
yyaxis(ax4,'left');
area(ax4, freq_hz_eval, amp_in_eval, 'FaceColor',[0.565 0.792 0.976],'FaceAlpha',0.4,'EdgeColor','none');
plot(ax4, freq_hz_eval, amp_in_eval, '--', 'Color',[0.086 0.396 0.753], 'LineWidth',1.2);
ylabel(ax4, 'Amplitud de Desplazamiento [m]', 'FontWeight','bold');
ymax_plot = max(amp_in_eval)*1.3; if ymax_plot <= 0, ymax_plot = 1.0; end
ylim(ax4, [0, ymax_plot]);

yyaxis(ax4,'right');
U_global_mm = max(U_node, [], 2) * 1e3;
plot(ax4, freq_hz_eval, U_global_mm, 'Color',[0.827 0.184 0.184], 'LineWidth',2.0);
ylabel(ax4, 'Desplazamiento Dinamico Maximo [mm]', 'Color','k','FontWeight','bold');
ymax_disp = max(U_global_mm)*1.2; if ymax_disp <= 0, ymax_disp = 1.0; end
ylim(ax4, [0, ymax_disp]);

res_raw = sort(unique(round(peak_freq_per_node,1)));
res_raw = res_raw(res_raw > 0);
res_grouped = [];
for k = 1:numel(res_raw)
    f = res_raw(k);
    if isempty(res_grouped) || abs(f - res_grouped(end)) > 0.5
        res_grouped(end+1) = f; %#ok<AGROW>
    end
end
resonance_freqs_unique = res_grouped(1:min(15,numel(res_grouped)));
for f_res = resonance_freqs_unique
    xline(ax4, f_res, '--', 'Color',[1.0 0.427 0.0], 'LineWidth',1.8);
end

freq_calc_show = freq_calc_valid(freq_calc_valid <= max(freq_hz_eval));
freq_calc_show = freq_calc_show(1:min(12,numel(freq_calc_show)));
for fc = freq_calc_show(:)'
    xline(ax4, fc, ':', 'Color',[0.18 0.49 0.196], 'LineWidth',1.2);
end

xlim(ax4, [0, max(freq_hz_eval)]);
xlabel(ax4, 'Frecuencia [Hz]');
title(ax4, sprintf(['Respuesta Frecuencial vs Fuerza de Entrada\n' ...
    '(naranja = resonancias nodales [%d]; verde = frec. naturales [%d])'], ...
    numel(resonance_freqs_unique), numel(freq_calc_show)), 'FontWeight','bold');
grid(ax4,'on'); ax4.GridAlpha=0.25; ax4.GridLineStyle='--';

h_leg4 = [patch(ax4,nan,nan,[0.565 0.792 0.976]), ...
          plot(ax4,nan,nan,'Color',[0.827 0.184 0.184],'LineWidth',2.0), ...
          plot(ax4,nan,nan,'--','Color',[1.0 0.427 0.0],'LineWidth',2.0), ...
          plot(ax4,nan,nan,':','Color',[0.18 0.49 0.196],'LineWidth',1.5)];
legend(h_leg4, {'Espectro fuerza entrante','Desplazamiento maximo calculado', ...
    'Freq. resonancia nodal (DLF max)','Freq. natural calculada'}, 'FontSize',8, 'Location','northeast');

save_fig_safe(fig4, fullfile(GRAFICAS_DIR,'Comparacion_Frecuencia.png'), GRAF('Comparacion_Frecuencia'));

% ---- espectros por nodo (uno por nodo) -------------------------------
if GRAF('Espectro_Nodos')
    fprintf('    Generando espectros por nodo (%d nodos) ...\n', n_nodes);
    for i = 1:n_nodes
        nid = node_ids(i);
        u_mm = U_node(:, i) * 1e3;
        f_in = amp_in_eval;

        if max(u_mm) > 1e-15
            min_dist = max(1, floor(n_freq/150));
            [pk_vals_full, pk_locs_full] = findpeaks(u_mm, ...
                'MinPeakProminence', max(max(u_mm)*0.08, 1e-15), 'MinPeakDistance', min_dist);
        else
            pk_vals_full = []; pk_locs_full = [];
        end

        if ~isempty(pk_locs_full)
            [~, i_best] = max(pk_vals_full);
            f_pico = freq_hz_eval(pk_locs_full(i_best));
        elseif max(u_mm) > 1e-15
            [~, idx_mx] = max(u_mm);
            f_pico = freq_hz_eval(idx_mx);
        else
            f_pico = 0.0;
        end

        f_max_plot = min(max(freq_hz_eval), max(f_pico*3.0, max(freq_hz_eval)*0.15));
        mask_plot = freq_hz_eval <= f_max_plot;
        fhz_p = freq_hz_eval(mask_plot);
        u_p   = u_mm(mask_plot);
        fin_p = f_in(mask_plot);

        fig_n = figure('Visible','off','Position',[100 100 1300 700]);
        ax_top = axes(fig_n, 'Position',[0.09 0.63 0.85 0.28]); hold(ax_top,'on');
        area(ax_top, fhz_p, fin_p, 'FaceColor',[0.086 0.396 0.753],'FaceAlpha',0.18,'EdgeColor','none');
        plot(ax_top, fhz_p, fin_p, 'Color',[0.086 0.396 0.753], 'LineWidth',1.3);
        ylabel(ax_top, 'Amplitud entrada [m]', 'FontSize',9);
        xlim(ax_top, [min(fhz_p), f_max_plot]); ylim(ax_top,[0, max(fin_p)*1.05+eps]);
        set(ax_top, 'XTickLabel', []);
        grid(ax_top,'on'); ax_top.GridAlpha=0.25; ax_top.GridLineStyle='--';
        title(ax_top, sprintf('Espectro de Respuesta -- Nodo %d  -  f_{pico} = %.3f Hz', nid, f_pico), 'FontWeight','bold');

        ax_bot = axes(fig_n, 'Position',[0.09 0.10 0.85 0.45]); hold(ax_bot,'on');
        plot(ax_bot, fhz_p, u_p, 'Color',[0.749 0.212 0.047], 'LineWidth',2.0);
        xlabel(ax_bot, 'Frecuencia [Hz]', 'FontSize',10); ylabel(ax_bot, 'Desplazamiento [mm]', 'FontSize',9);
        xlim(ax_bot, [min(fhz_p), f_max_plot]);
        if max(u_p) > 0, ylim(ax_bot, [0, max(u_p)*1.35]); else, ylim(ax_bot,[0,1]); end
        grid(ax_bot,'on'); ax_bot.GridAlpha=0.25; ax_bot.GridLineStyle='--';

        if ~isempty(pk_locs_full)
            pk_vis = pk_locs_full(freq_hz_eval(pk_locs_full) <= f_max_plot);
            if ~isempty(pk_vis)
                [~, ord_amp] = sort(u_mm(pk_vis), 'descend');
                pk_vis = pk_vis(ord_amp);
                pk_vis = pk_vis(1:min(4,numel(pk_vis)));
                [~, ord_freq] = sort(freq_hz_eval(pk_vis));
                pk_vis = pk_vis(ord_freq);
            end
        else
            pk_vis = [];
        end
        for p_idx = 1:numel(pk_vis)
            pidx = pk_vis(p_idx);
            pf = freq_hz_eval(pidx);
            xline(ax_bot, pf, '--', 'Color',[1.0 0.427 0.0], 'LineWidth',1.4);
            xline(ax_top, pf, '--', 'Color',[1.0 0.427 0.0], 'LineWidth',1.2);
            y_top_lim = ax_bot.YLim(2);
            y_ann = y_top_lim * (0.92 - 0.15*mod(p_idx-1,3));
            text(ax_bot, pf, y_ann, sprintf('%.2f Hz', pf), 'FontSize',7.5, 'Color',[0.902 0.318 0.0], ...
                 'HorizontalAlignment','center');
        end

        fn_visible = freq_calc_valid(freq_calc_valid <= f_max_plot);
        fn_visible = fn_visible(1:min(4,numel(fn_visible)));
        for fm = fn_visible(:)'
            xline(ax_bot, fm, ':', 'Color',[0.18 0.49 0.196], 'LineWidth',1.0);
            xline(ax_top, fm, ':', 'Color',[0.18 0.49 0.196], 'LineWidth',0.9);
        end

        h_leg_n = [plot(ax_bot,nan,nan,'Color',[0.086 0.396 0.753],'LineWidth',2.0), ...
                   plot(ax_bot,nan,nan,'Color',[0.749 0.212 0.047],'LineWidth',2.0), ...
                   plot(ax_bot,nan,nan,'--','Color',[1.0 0.427 0.0],'LineWidth',1.5), ...
                   plot(ax_bot,nan,nan,':','Color',[0.18 0.49 0.196],'LineWidth',1.0)];
        legend(h_leg_n, {'Amplitud entrada [m]', sprintf('Respuesta nodo %d [mm]', nid), ...
            'Pico de respuesta', 'Frec. natural'}, 'FontSize',8, 'Location','northeast');

        save_fig_safe(fig_n, fullfile(SPEC_DIR, sprintf('espectro_nodo_%d.png', nid)), true);
    end
else
    fprintf('    Espectros por nodo: omitidos (Graficas=n)\n');
end
fprintf('    Figuras guardadas (%d espectros + figuras globales).\n', n_nodes);

 
%% 11. EXPORTAR RESULTADOS A EXCEL (10 hojas)
 
fprintf('\n[%s] [PASO 11/11] Exportando resultados -> ''%s'' ...\n', elapsed(), OUTPUT_XLSX);

if exist(OUTPUT_XLSX, 'file')
    delete(OUTPUT_XLSX);   % empezamos limpio, no sea que queden hojas viejas de una corrida anterior
end

node_uf = zeros(n_nodes, 1);
for ie = 1:n_elem
    fu_val = elem_uf(ie);
    if isfinite(fu_val)
        ni = elem_info(ie).ni; nj = elem_info(ie).nj;
        node_uf(ni) = max(node_uf(ni), fu_val);
        node_uf(nj) = max(node_uf(nj), fu_val);
    end
end

sheet_names_order  = {};
sheet_data_all      = {};
sheet_fillcode_all  = {};

% ---- Resumen_Nodos --------------------------------------------------
h1 = {'Nodo','X [m]','Y [m]','Z [m]','Masa X [kg]','Masa Y [kg]','Masa Z [kg]', ...
      'sigma_vm Max. [MPa]','Factor DLF','Freq DLF max [Hz]', ...
      'Freq Pico Disp. [Hz]','Idx Resonancia Beta','Desp. Din. Max. [m]','Criticidad'};
d1 = cell(n_nodes, numel(h1)); fc1 = cell(n_nodes, 1);
for i = 1:n_nodes
    if node_uf(i) >= 1.0,     criti = 'ALTA (Colapso)'; fc1{i} = 'red';
    elseif node_uf(i) >= 0.75, criti = 'MEDIA (Alerta)'; fc1{i} = 'yellow';
    else,                      criti = 'BAJA';            fc1{i} = 'none';
    end
    d1(i,:) = {node_ids(i), round(x_pos(i),4), round(y_pos(i),4), round(z_pos(i),4), ...
               round(mass_x(i),4), round(mass_y(i),4), round(mass_z(i),4), ...
               round(node_stress_MPa(i),6), round(DLF_node(i),4), round(dlf_freq_per_node(i),3), ...
               round(peak_freq_per_node(i),3), round(resonance_beta(i),4), round(U_max_node(i),8), criti};
end
sheet_names_order{end+1} = 'Resumen_Nodos'; sheet_data_all{end+1} = [h1; d1]; sheet_fillcode_all{end+1} = fc1;

% ---- Estres_Elementos -------------------------------------------------
h2 = {'Elem.','Nodo I','Nodo J','L [m]','E [Pa]','A [m2]','Densidad [kg/m3]','Iy [m4]','Iz [m4]', ...
      'C_y [m]','C_z [m]','Zp [m3]','Zeta (amortiguamiento)','Sigma_y [Pa]','Sigma_u [Pa]', ...
      'sigma_vm Max. [Pa]','sigma_vm Max. [MPa]','FS (= sigma_lim / sigma_vm)','FU (= sigma_vm / sigma_lim)','Estado'};
d2 = cell(n_elem, numel(h2)); fc2 = cell(n_elem, 1);
for ie = 1:n_elem
    ei = elem_info(ie);
    if ei.fail_u,     estado = 'Roto (u)';
    elseif ei.fail_y, estado = 'Cedido (y)';
    else,             estado = 'Seguro';
    end
    fu_check = elem_uf(ie); if isnan(fu_check), fu_check = 0.0; end
    if fu_check >= 1.0,     fc2{ie} = 'red';
    elseif fu_check >= 0.8, fc2{ie} = 'yellow';
    else,                   fc2{ie} = 'none';
    end
    if isfinite(ei.sigma_y), sy_str = sprintf('%.3e', ei.sigma_y); else, sy_str = 'N/A'; end
    if isfinite(ei.sigma_u), su_str = sprintf('%.3e', ei.sigma_u); else, su_str = 'N/A'; end
    d2(ie,:) = {ei.elem_id, ei.ni_id, ei.nj_id, round(ei.L,4), round(ei.E,2), round(ei.A_sec,8), ...
                round(ei.rho,4), round(ei.Iy,10), round(ei.Iz,10), round(ei.ymax,6), round(ei.zmax,6), ...
                round(ei.zp,8), round(ei.zeta,4), sy_str, su_str, ...
                round(elem_stress_max_Pa(ie),4), round(elem_stress_max_MPa(ie),6), ...
                fmt_val(elem_sf(ie)), fmt_val(elem_uf(ie)), estado};
end
sheet_names_order{end+1} = 'Estres_Elementos'; sheet_data_all{end+1} = [h2; d2]; sheet_fillcode_all{end+1} = fc2;

% ---- Modos_Naturales ----------------------------------------------
h3 = {'Modo','w_n [rad/s]','f_n [Hz]','Tipo','Despl. Modal Max.','Nodo Critico (Estres)','Elemento Critico (Estres)'};
n_modes_report = min(n_modes, 100);
d3 = cell(n_modes_report, numel(h3));
for r = 1:n_modes_report
    if freq_n(r) < 0.1, tipo = 'Rigido'; else, tipo = 'Flexible'; end
    phi = eigenvectors(:, r);
    stress_modal_nodos = zeros(n_nodes,1);
    max_s_vm_elem = -1.0; elem_critico_id = -1;
    for k = 1:n_valid
        s_vm_modal = von_mises_elem(elem_info(k), phi);   % helper reutilizado, evita duplicar formulas
        ni = elem_info(k).ni; nj = elem_info(k).nj;
        stress_modal_nodos(ni) = max(stress_modal_nodos(ni), s_vm_modal);
        stress_modal_nodos(nj) = max(stress_modal_nodos(nj), s_vm_modal);
        if s_vm_modal > max_s_vm_elem
            max_s_vm_elem = s_vm_modal;
            elem_critico_id = elem_info(k).elem_id;
        end
    end
    [~, idx_nodo_max] = max(stress_modal_nodos);
    nodo_max_estres = node_ids(idx_nodo_max);
    phi_tr = zeros(n_nodes,1);
    for i = 1:n_nodes
        b = DOF_PER_NODE*(i-1);
        phi_tr(i) = sqrt(phi(b+1)^2 + phi(b+2)^2 + phi(b+3)^2);
    end
    d3(r,:) = {r, round(omega_n(r),4), round(freq_n(r),4), tipo, round(max(phi_tr),6), nodo_max_estres, elem_critico_id};
end
sheet_names_order{end+1} = 'Modos_Naturales'; sheet_data_all{end+1} = [h3; d3];
sheet_fillcode_all{end+1} = repmat({'none'}, n_modes_report, 1);

% ---- Carga_Escalon (si existe) -------------------------------------
if ~isempty(escalon_data) && height(escalon_data) > 0
    cols_esc = escalon_data.Properties.VariableNames;
    d_esc = table2cell(escalon_data);
    sheet_names_order{end+1} = 'Carga_Escalon';
    sheet_data_all{end+1}    = [cols_esc; d_esc];
    sheet_fillcode_all{end+1}= repmat({'none'}, size(d_esc,1), 1);
end

% ---- Comparacion_Frecuencias ----------------------------------------
h5 = {'f_medida [Hz]', sprintf('Amp_medida %s', AMP_UNIT_LABEL), 'f_calculada [Hz]', 'Error [%]'};
n_cmp = numel(comparison_rows);
d5 = cell(n_cmp, numel(h5)); fc5 = cell(n_cmp, 1);
for r = 1:n_cmp
    rowc = comparison_rows(r);
    if rowc.Error_pct > 20,     fc5{r} = 'red';
    elseif rowc.Error_pct > 10, fc5{r} = 'orange';
    else,                       fc5{r} = 'none';
    end
    d5(r,:) = {rowc.f_medida_Hz, rowc.Amp_medida_m, rowc.f_calculada_Hz, rowc.Error_pct};
end
sheet_names_order{end+1} = 'Comparacion_Frecuencias'; sheet_data_all{end+1} = [h5; d5]; sheet_fillcode_all{end+1} = fc5;

% ---- Espectro_Nodal (submuestreado) ---------------------------------
h6 = [{'Frec [Hz]', sprintf('Amp Entrada Original %s', AMP_UNIT_LABEL)}, ...
      arrayfun(@(nid) sprintf('Respuesta Nodo %d [mm]', nid), node_ids, 'UniformOutput', false).'];
step5 = max(1, floor(n_freq / 500));
idxs6 = 1:step5:n_freq;
d6 = cell(numel(idxs6), numel(h6));
for r = 1:numel(idxs6)
    k = idxs6(r);
    row_vals = [round(freq_hz_eval(k),4), round(amp_in_eval(k),6), round(U_node(k,:)*1e3, 6)];
    d6(r,:) = num2cell(row_vals);
end
sheet_names_order{end+1} = 'Espectro_Nodal'; sheet_data_all{end+1} = [h6; d6];
sheet_fillcode_all{end+1} = repmat({'none'}, numel(idxs6), 1);

% ---- Resonancia_Nodos ------------------------------------------------
h7 = {'Nodo','Factor DLF','Freq DLF max [Hz]','Freq Pico Disp [Hz]','Idx Resonancia Beta','Desp. Din. Max. [m]'};
d7 = cell(n_nodes, numel(h7)); fc7 = cell(n_nodes, 1);
for i = 1:n_nodes
    if resonance_beta(i) > 0.9 && resonance_beta(i) < 1.1, fc7{i} = 'red'; else, fc7{i} = 'none'; end
    d7(i,:) = {node_ids(i), round(DLF_node(i),4), round(dlf_freq_per_node(i),3), ...
               round(peak_freq_per_node(i),3), round(resonance_beta(i),4), round(U_max_node(i),8)};
end
sheet_names_order{end+1} = 'Resonancia_Nodos'; sheet_data_all{end+1} = [h7; d7]; sheet_fillcode_all{end+1} = fc7;

% ---- Graficas (config exportada) -------------------------------------
h8 = {'Grafica','Exportar'};
d8 = cell(numel(GRAF_KEYS), 2);
for k = 1:numel(GRAF_KEYS)
    if GRAF(GRAF_KEYS{k}), val_s = 's'; else, val_s = 'n'; end
    d8(k,:) = {GRAF_KEYS{k}, val_s};
end
sheet_names_order{end+1} = 'Graficas'; sheet_data_all{end+1} = [h8; d8];
sheet_fillcode_all{end+1} = repmat({'none'}, numel(GRAF_KEYS), 1);

% ---- Advertencias_Malla -----------------------------------------------
all_msgs = [mesh_warnings, mesh_errors];  % mesh_errors siempre vacio a estas alturas
h9 = {'Advertencias / Errores detectados en la malla'};
d9 = cell(numel(all_msgs), 1);
for k = 1:numel(all_msgs), d9{k,1} = all_msgs{k}; end
sheet_names_order{end+1} = 'Advertencias_Malla'; sheet_data_all{end+1} = [h9; d9];
sheet_fillcode_all{end+1} = repmat({'none'}, numel(all_msgs), 1);

% ---- Metodologia -------------------------------------------------------
metodologia = {
    'Ecuacion de movimiento',    'M*u''''(t) + C*u''(t) + K*u(t) = F_0*e^(iwt) + F_grav';
    'Matriz de Masa',            'Masa Consistente: M = int(rho*A*N^T*N dx) (inercia rotacional + J)';
    'Solver',                    sprintf('%s -- %d modos', SOLVER, n_modes);
    'Matrices dispersas',        'K y M ensambladas como sparse (row,col,data) -> sparse()';
    'Amortiguamiento Modal',     'zeta_r = sum_e(phi_r^T K_e phi_r * zeta_e) / sum_e(phi_r^T K_e phi_r)';
    'Solucion Modal (Freq)',     'u(w) = sum_r phi_r * gamma_r * F_0(w) * |H_r(w)| / wn_r^2';
    'Carga de Pulso',            'No implementada (bug del script original: se calculaba y se descartaba)';
    'Gravedad (Z)',              'F_grav = -M_nodal * g * ez (carga estatica inicial, superpuesta)';
    'Von Mises',                 'sigma_vm = sqrt(sigma_x^2 + 3*tau^2), sigma_x = N/A + My*z/Iy + Mz*y/Iz';
    'Factor de Seguridad',       'FS = sigma_limite / sigma_vm (sigma_limite = Sigma_y si existe, si no Sigma_u)';
    'Factor de Utilizacion',     'FU = sigma_vm / sigma_limite -> amarillo [0.8,1.0), rojo >= 1.0';
    'Factor DLF',                'DLF = max_w [ |u(w)| / (u_st_nodo * F(w)) ]';
    'Indice de Resonancia Beta', 'Beta = Freq_pico_actuante / Freq_natural_mas_cercana. Critico si Beta ~ 1.0';
};
h10 = {'Concepto','Formula / Descripcion'};
sheet_names_order{end+1} = 'Metodologia'; sheet_data_all{end+1} = [h10; metodologia];
sheet_fillcode_all{end+1} = repmat({'none'}, size(metodologia,1), 1);

% --- Paso A: escribir TODOS los datos primero (esto no puede fallar por
% no tener Excel instalado, writecell no depende de COM) ---
for si = 1:numel(sheet_names_order)
    writecell(sheet_data_all{si}, OUTPUT_XLSX, 'Sheet', sheet_names_order{si});
end
fprintf('    [OK] Datos escritos en %d hojas.\n', numel(sheet_names_order));

% --- Paso B: formato visual, best-effort. Si Excel no esta disponible o
% algo truena, los datos de arriba ya estan a salvo -- solo avisamos y
% seguimos, nunca dejamos que el estilo tumbe el resultado. ---
fprintf('    Aplicando formato (best-effort, Excel COM) ...\n');
try
    apply_excel_styling(OUTPUT_XLSX, sheet_names_order, sheet_data_all, sheet_fillcode_all);
    fprintf('    [OK] Formato aplicado.\n');
catch ME_style
    fprintf('    [AVISO] No se pudo aplicar formato (%s).\n', ME_style.message);
    fprintf('            El archivo sigue siendo valido, solo sin colores/estilos.\n');
end

 
%% 12. ANIMACION (5s reales, camara lenta, 30fps)
 
fprintf('\n[%s] [PASO 12] Generando simulacion dinamica ...\n', elapsed());

if ~GRAF('Simulacion (10s)')
    fprintf('    Simulacion: omitida (Graficas=n)\n');
else
    try
        resp_global = max(abs(U_dof_complex), [], 2);
        peak_idxs = [];
        for i = 2:(numel(resp_global)-1)
            if resp_global(i) > resp_global(i-1) && resp_global(i) > resp_global(i+1)
                peak_idxs(end+1) = i; %#ok<AGROW>
            end
        end
        [~, ord] = sort(resp_global(peak_idxs), 'descend');
        peak_idxs_sorted = peak_idxs(ord);
        if numel(peak_idxs_sorted) >= 2,     idx_peak = peak_idxs_sorted(2);
        elseif numel(peak_idxs_sorted) >= 1, idx_peak = peak_idxs_sorted(1);
        else,                                idx_peak = 1;
        end

        f_real = omega_eval(idx_peak) / (2*pi);
        U_peak = U_dof_complex(idx_peak, :);

        f_visual = 0.5; w_visual = 2*pi*f_visual;
        duration = 5.0; fps = 30;
        n_frames = round(duration * fps);
        t_vec = linspace(0, duration, n_frames);

        fprintf('    Simulacion: Modo Secundario (%.2f Hz) | Camara lenta: %.1f Hz visual\n', f_real, f_visual);

        u_grav = u_grav_full;
        max_amp = max(abs(U_peak));
        max_total = max_amp;  % sin escalon, ver notas de PASO 8b
        if max_total > 1e-12, scale = rango_geom * 0.05 / max_total; else, scale = 1.0; end

        U_frames = zeros(n_frames, dof_total);
        for fi = 1:n_frames
            U_frames(fi, :) = real(U_peak * exp(1i * w_visual * t_vec(fi)));
        end

        fig_anim = figure('Visible','off', 'Position',[100 100 1100 800]);
        if use_3d_plot
            ax_anim = axes(fig_anim); hold(ax_anim,'on'); view(ax_anim,3);
        else
            ax_anim = axes(fig_anim); hold(ax_anim,'on'); axis(ax_anim,'equal');
        end
        xlabel(ax_anim,'X [m]','FontWeight','bold'); ylabel(ax_anim,'Y [m]','FontWeight','bold');
        if use_3d_plot, zlabel(ax_anim,'Z [m]','FontWeight','bold'); end
        grid(ax_anim,'on'); ax_anim.GridLineStyle='--'; ax_anim.GridAlpha=0.4;

        pos_grav_x = x_pos + u_grav(1:6:end);
        pos_grav_y = y_pos + u_grav(2:6:end);
        pos_grav_z = z_pos + u_grav(3:6:end);

        h_lines = gobjects(n_valid,1);
        for k = 1:n_valid
            ei = elem_info(k); ni = ei.ni; nj = ei.nj;
            if use_3d_plot
                h_lines(k) = plot3(ax_anim, [pos_grav_x(ni),pos_grav_x(nj)], ...
                    [pos_grav_y(ni),pos_grav_y(nj)], [pos_grav_z(ni),pos_grav_z(nj)], 'LineWidth',2.5);
            else
                h_lines(k) = plot(ax_anim, [pos_grav_x(ni),pos_grav_x(nj)], ...
                    [pos_grav_y(ni),pos_grav_y(nj)], 'LineWidth',2.5);
            end
        end

        stress_ref = zeros(n_valid,1);
        for k = 1:n_valid
            stress_ref(k) = von_mises_elem(elem_info(k), u_grav + real(U_peak(:)));
        end
        vmax_anim = max(max(stress_ref), max(elem_stress_max_MPa));
        if vmax_anim <= 0, vmax_anim = 1e-12; end
        colormap(ax_anim, cmap_stress_array(256));
        caxis(ax_anim, [0, vmax_anim]);
        cb_anim = colorbar(ax_anim); cb_anim.Label.String = 'sigma_vm [MPa]';
        title(ax_anim, sprintf('Simulacion Dinamica (Modo: %.2f Hz)\nEscala Visual: %.0fx', f_real, scale), 'FontWeight','bold');
        txt_time = text(ax_anim, 0.02, 0.95, '', 'Units','normalized', 'FontWeight','bold', 'Color','black');

        m = rango_geom * 0.7;
        xlim(ax_anim, [mean(pos_grav_x)-m, mean(pos_grav_x)+m]);
        ylim(ax_anim, [mean(pos_grav_y)-m, mean(pos_grav_y)+m]);
        if use_3d_plot, zlim(ax_anim, [mean(pos_grav_z)-m, mean(pos_grav_z)+m]); end

        gif_path = fullfile(GRAFICAS_DIR, 'simulacion_10s.gif');
        for fi = 1:n_frames
            u_vib = U_frames(fi, :)';
            disp_vis = u_grav + u_vib * scale;
            stress_t = zeros(n_valid,1);
            for k = 1:n_valid
                stress_t(k) = von_mises_elem(elem_info(k), u_grav + u_vib);
            end
            txt_time.String = sprintf('t: %.2f s | Escala: %.0fx', t_vec(fi), scale);
            for k = 1:n_valid
                ei = elem_info(k); ni = ei.ni; nj = ei.nj;
                xi = x_pos(ni) + disp_vis(6*(ni-1)+1); xj = x_pos(nj) + disp_vis(6*(nj-1)+1);
                yi = y_pos(ni) + disp_vis(6*(ni-1)+2); yj = y_pos(nj) + disp_vis(6*(nj-1)+2);
                zi = z_pos(ni) + disp_vis(6*(ni-1)+3); zj = z_pos(nj) + disp_vis(6*(nj-1)+3);
                col = cmap_stress(stress_t(k) / vmax_anim);
                set(h_lines(k), 'Color', col);
                if use_3d_plot
                    set(h_lines(k), 'XData',[xi,xj], 'YData',[yi,yj], 'ZData',[zi,zj]);
                else
                    set(h_lines(k), 'XData',[xi,xj], 'YData',[yi,yj]);
                end
            end
            drawnow;
            frame_cap = getframe(fig_anim);
            im = frame2im(frame_cap);
            [imind, cmgif] = rgb2ind(im, 256);
            if fi == 1
                imwrite(imind, cmgif, gif_path, 'gif', 'Loopcount', inf, 'DelayTime', 1/fps);
            else
                imwrite(imind, cmgif, gif_path, 'gif', 'WriteMode', 'append', 'DelayTime', 1/fps);
            end
        end
        close(fig_anim);
        fprintf('    [OK] simulacion_10s.gif (f_real=%.2f Hz, escala=%.0fx)\n', f_real, scale);
    catch ME_anim
        fprintf('    [AVISO] No se pudo generar la animacion: %s\n', ME_anim.message);
    end
end

 
%% 13. RESUMEN FINAL
 
fprintf('\n  ARCHIVOS GENERADOS\n');
fprintf('  %s\n', repmat('-',1,55));
archivos_generados = {
    OUTPUT_XLSX,                                            'Reporte Excel (10 hojas)',          true;
    fullfile(GRAFICAS_DIR,'Mapa_Estres_Calor.png'),          'Mapa de calor Von Mises',            GRAF('Mapa_Estres');
    fullfile(GRAFICAS_DIR,'Mapa_Estres_Barras.png'),         'sigma_vm por elemento',              GRAF('Mapa_Estres');
    fullfile(GRAFICAS_DIR,'Mapa_Deformacion.png'),           'Deformacion epsilon por elemento',   GRAF('Mapa_Deformacion');
    fullfile(GRAFICAS_DIR,'Mapa_Elementos.png'),             'Esquema de numeracion',              GRAF('Mapa_Elementos');
    fullfile(GRAFICAS_DIR,'FS_Elementos.png'),               'Factor de seguridad FS',             GRAF('FS_Elementos');
    fullfile(GRAFICAS_DIR,'FU_Elementos.png'),               'Factor de utilizacion FU',           GRAF('FU_Elementos');
    fullfile(GRAFICAS_DIR,'Factor_DLF.png'),                 'Factor DLF por nodo',                GRAF('Factor_DLF');
    fullfile(GRAFICAS_DIR,'Resonancia_beta.png'),            'Indice de resonancia Beta',          GRAF('Resonancia_beta');
    fullfile(GRAFICAS_DIR,'Frecuencia_Pico.png'),            'Frecuencia Pico por nodo',            GRAF('Frecuencia_Pico');
    fullfile(GRAFICAS_DIR,'Comparacion_Frecuencia.png'),     'Respuesta frecuencial global',        GRAF('Comparacion_Frecuencia');
    fullfile(GRAFICAS_DIR,'simulacion_10s.gif'),             'Animacion dinamica',                  GRAF('Simulacion (10s)');
    [MODAL_DIR filesep],                                     sprintf('Modos normales 1-%d', N_MODES_PLOT), GRAF('Modos_Normales');
    [SPEC_DIR filesep],                                      sprintf('Espectros por nodo (%d archivos)', n_nodes), GRAF('Espectro_Nodos');
};
for r = 1:size(archivos_generados,1)
    if archivos_generados{r,3}, estado = '[OK]'; else, estado = '[--]'; end
    fprintf('  %s  %-42s %s\n', estado, archivos_generados{r,1}, archivos_generados{r,2});
end
fprintf('  %s\n', repmat('-',1,55));
fprintf('  Tiempo total de ejecucion: %s\n', elapsed());
fprintf('%s\n\n', repmat('=',1,65));

 
%% 14. RESUMEN DE PARAMETROS PERTINENTES
 
fprintf('  RESUMEN DE PARAMETROS PERTINENTES\n');
fprintf('  %s\n', repmat('-',1,55));
fprintf('  Modos calculados            : %d\n', n_modes);
fprintf('  Frecuencia dominante (Hz)   : %.3f\n', f_excit_dominante);
fprintf('  Max factor dinamico (DLF)   : %.3f\n', max(DLF_node));
fprintf('  Max indice resonancia Beta  : %.3f\n', max(resonance_beta));
if ~isempty(elem_stress_max_MPa)
    fprintf('  Max estres Von Mises (MPa)  : %.3f\n', max(elem_stress_max_MPa));
end
fprintf('  Max deformacion epsilon     : %.3f uE\n', max(elem_strain_max)*1e6);
fprintf('  Nodos en riesgo (resonancia): %d\n', n_resonantes);
fprintf('%s\n\n', repmat('=',1,65));


%% -----------------------------------------------------------------
%% SUB-FUNCIONES AUXILIARES
%% -----------------------------------------------------------------

function val = local_get_fallback(tbl, candidates, default_val, row_idx)
    % probando una lista de nombres de columna candidatos (ya
    % sanitizados al estilo readtable) y devolviendo el default si
    % ninguno existe. Porque el excel nunca trae las columnas con el
    % nombre que uno espera, NUUUUNCAAAAAAAAAAAAAAAAAAAAAAAAAAAA X(.
    val = default_val;
    vn = tbl.Properties.VariableNames;
    for c = 1:numel(candidates)
        if ismember(candidates{c}, vn)
            colvals = tbl.(candidates{c});
            val = colvals(row_idx);
            return;
        end
    end
end

function T3 = rotation_matrix_3d(dx, dy, dz, Lv)
    % Extrayendo vectores directores para no perder el norte tridimensional
    ex = [dx, dy, dz] / Lv;
    candidates = [0,0,1; 0,1,0; 1,0,0];
    for i = 1:3
        aux = candidates(i, :);
        ey = cross(aux, ex);
        n = norm(ey);
        if n > 1e-10
            ey = ey / n;
            ez = cross(ex, ey);
            T3 = [ex; ey; ez];
            return;
        end
    end
    T3 = eye(3);
end

function T12 = make_T12(R3)
    % Multiplicando la matriz por bloques. Qué lindo es MATLAB para esto
    T12 = zeros(12, 12);
    for blk = 0:3
        idx = (3*blk+1):(3*blk+3);
        T12(idx, idx) = R3;
    end
end

function Ky = flex_block_XY(EIz, Lv)
    % Rigidez clasica de flexion pura, plano local XY.
    % DOFs: [v_i, +theta_z_i, v_j, +theta_z_j]
    % Ref: Cook et al., Concepts and Applications of FEA, 4th ed., ec. 2.3-7
    c = EIz / Lv^3;
    Ky = c * [ 12.0,     6.0*Lv,   -12.0,     6.0*Lv; ...
                6.0*Lv,  4.0*Lv^2,  -6.0*Lv,  2.0*Lv^2; ...
              -12.0,    -6.0*Lv,    12.0,    -6.0*Lv; ...
                6.0*Lv,  2.0*Lv^2,  -6.0*Lv,  4.0*Lv^2 ];
end

function Kz = flex_block_XZ(EIy, Lv)
    % Lo mismo de arriba pero pal otro eje, plano local XZ.
    % OJO: theta_y lleva signo negativo por la regla de la mano derecha,
    % la matriz es identica a flex_block_XY por simetria de la viga
    % prismatica pero el signo fisico de theta_y hay que respetarlo al
    % recuperar momentos despues (von_mises_elem usa F(5)/F(11) tal cual).
    % Ref: Przemieniecki, Theory of Matrix Structural Analysis, ec. 4.19
    c = EIy / Lv^3;
    Kz = c * [ 12.0,     6.0*Lv,   -12.0,     6.0*Lv; ...
                6.0*Lv,  4.0*Lv^2,  -6.0*Lv,  2.0*Lv^2; ...
              -12.0,    -6.0*Lv,    12.0,    -6.0*Lv; ...
                6.0*Lv,  2.0*Lv^2,  -6.0*Lv,  4.0*Lv^2 ];
end

function M = consistent_mass_12(m_total, L, A_sec, J)
    % Matriz de masa consistente 12x12 en coordenadas locales, viga EB 3D.
    % Ref: Cook et al., Concepts and Applications of FEA, 4th ed.
    % Esta matriz me costo tres cafes entenderla en su momento y sigue
    % costando el cuarto.
    M = zeros(12, 12);
    c = m_total / 420.0;
    c_torsion = (m_total * J / (A_sec + 1e-20)) / 6.0;

    M(1,1) = 140*c; M(1,7) = 70*c; M(7,1) = 70*c; M(7,7) = 140*c;
    M(4,4) = 2*c_torsion; M(4,10) = 1*c_torsion; M(10,4) = 1*c_torsion; M(10,10) = 2*c_torsion;

    idx_xy = [2, 6, 8, 12];
    M_xy = c * [ 156,    22*L,    54,    -13*L; ...
                 22*L,   4*L^2,   13*L,   -3*L^2; ...
                 54,     13*L,   156,    -22*L; ...
                -13*L,  -3*L^2,  -22*L,    4*L^2 ];
    M(idx_xy, idx_xy) = M(idx_xy, idx_xy) + M_xy;

    idx_xz = [3, 5, 9, 11];
    M_xz = c * [ 156,    22*L,    54,    -13*L; ...
                 22*L,   4*L^2,   13*L,   -3*L^2; ...
                 54,     13*L,   156,    -22*L; ...
                -13*L,  -3*L^2,  -22*L,    4*L^2 ];
    M(idx_xz, idx_xz) = M(idx_xz, idx_xz) + M_xz;
end

function sigma_vm_MPa = von_mises_elem(ei, u_global_real)
    % El jefe final: Criterio de Von Mises para ver si la viga explota.
    % (usado para casos de un solo vector de desplazamiento real; el
    % calculo dinamico completo con gravedad+espectro esta en PASO 8
    % arriba, esta funcion queda como utilidad standalone)
    u_loc = ei.T12 * u_global_real(ei.dofs_e);
    F = ei.Kl * u_loc;

    N_  = abs(F(7));
    My_ = max(abs(F(5)), abs(F(11)));
    Mz_ = max(abs(F(6)), abs(F(12)));
    T_  = max(abs(F(4)), abs(F(10)));

    sx = 0;
    if ei.A_sec > 0, sx = sx + (N_ / ei.A_sec); end
    if ei.Iy > 0 && ei.zmax > 0, sx = sx + (My_ * ei.zmax / ei.Iy); end
    if ei.Iz > 0 && ei.ymax > 0, sx = sx + (Mz_ * ei.ymax / ei.Iz); end

    tau = 0;
    if ei.zp > 0, tau = T_ / ei.zp; end

    sigma_vm_MPa = sqrt(sx^2 + 3.0 * tau^2) / 1e6;
end

function rgb = cmap_stress(t)
    % El colormap "BlueOrange". t debe venir en [0,1] (ya normalizado).
    c1 = [21,101,192]/255;   % #1565C0 azul
    c2 = [224,224,224]/255;  % #e0e0e0 gris claro
    c3 = [255,111,0]/255;    % #FF6F00 naranja
    t = min(max(t,0),1);
    if isnan(t), t = 0; end
    if t <= 0.5
        frac = t/0.5;
        rgb = c1 + frac*(c2-c1);
    else
        frac = (t-0.5)/0.5;
        rgb = c2 + frac*(c3-c2);
    end
end

function cmap = cmap_stress_array(n)
    % Version discretizada de cmap_stress para usar con colormap()/caxis()
    % en las barras de color (colorbar necesita una tabla Nx3, no una
    % funcion continua).
    cmap = zeros(n,3);
    for i = 1:n
        cmap(i,:) = cmap_stress((i-1)/(n-1));
    end
end

function save_fig_safe(fig, path, do_save)
    % Guarda-y-cierra centralizado para que cada figura del script no
    % tenga que repetir su propio try/catch. Si exportgraphics falla
    % (version vieja de MATLAB, ruta rara, lo que sea) cae a print(), y
    % si ESO tambien falla, solo avisa -- nunca deja una figura abierta
    % colgada ni tumba el script completo por una sola grafica.
    if do_save
        try
            exportgraphics(fig, path, 'BackgroundColor','white');
        catch
            try
                print(fig, path, '-dpng', '-r150');
            catch ME
                fprintf('    [AVISO] No se pudo guardar %s: %s\n', path, ME.message);
            end
        end
    end
    close(fig);
end

function out = fmt_val(v)
    %  NaN -> "N/A", Inf -> "Inf" (texto plano,
    % no el simbolo unicode, para no arriesgarnos con encodings raros al
    % escribir el xlsx), numero -> redondeado a 4 decimales.
    if isnan(v)
        out = 'N/A';
    elseif isinf(v)
        out = 'Inf';
    else
        out = round(v, 4);
    end
end

function apply_excel_styling(filepath, sheet_names_order, sheet_data_all, sheet_fillcode_all)
    % Estilo "best effort" via automatizacion COM de Excel (solo Windows
    % con Excel instalado). Si CUALQUIER cosa aqui adentro truena, el
    % try/catch del llamador ya nos cubre -- los datos ya estan guardados
    % sin estilo, asi que aqui podemos dejar que un error tumbe todo el
    % intento sin miedo. onCleanup garantiza que Excel se cierre bien
    % aunque algo falle a mitad del formateo (nada de procesos de Excel
    % huerfanos colgados en el Administrador de Tareas).
    full_path = char(java.io.File(filepath).getAbsolutePath());

    excelApp = actxserver('Excel.Application');
    excelApp.Visible = false;
    excelApp.DisplayAlerts = false;
    cleanupApp = onCleanup(@() safe_quit_excel(excelApp)); %#ok<NASGU>

    wbCom = excelApp.Workbooks.Open(full_path);
    cleanupWb = onCleanup(@() safe_close_wb(wbCom)); %#ok<NASGU>

    % Quitar hojas huerfanas que no sean nuestras (p.ej. "Hoja1" default)
    for si = wbCom.Sheets.Count:-1:1
        shName = wbCom.Sheets.Item(si).Name;
        if ~ismember(shName, sheet_names_order)
            wbCom.Sheets.Item(si).Delete();
        end
    end

    hdr_rgb    = bgr(31, 78, 121);
    fill_a_rgb = bgr(222, 234, 241);
    red_rgb    = bgr(255, 107, 107);
    org_rgb    = bgr(255, 224, 178);
    yel_rgb    = bgr(255, 255, 153);

    for si = 1:numel(sheet_names_order)
        ws = wbCom.Sheets.Item(sheet_names_order{si});
        data = sheet_data_all{si};
        n_rows_data = size(data,1) - 1;
        n_cols = size(data,2);
        if n_rows_data < 0, n_rows_data = 0; end

        hdr_range = ws.Range(ws.Cells(1,1), ws.Cells(1, n_cols));
        hdr_range.Interior.Color = hdr_rgb;
        hdr_range.Font.Color = bgr(255,255,255);
        hdr_range.Font.Bold = true;
        hdr_range.Font.Name = 'Calibri';
        hdr_range.Font.Size = 10;
        hdr_range.HorizontalAlignment = -4108; % xlCenter
        hdr_range.VerticalAlignment   = -4108;
        hdr_range.Borders.LineStyle = 1;

        if n_rows_data > 0
            data_range = ws.Range(ws.Cells(2,1), ws.Cells(1+n_rows_data, n_cols));
            data_range.Font.Name = 'Calibri';
            data_range.Font.Size = 9;
            data_range.HorizontalAlignment = -4108;
            data_range.VerticalAlignment   = -4108;
            data_range.Borders.LineStyle = 1;

            for r = 2:2:(1+n_rows_data)
                ws.Range(ws.Cells(r,1), ws.Cells(r,n_cols)).Interior.Color = fill_a_rgb;
            end

            fillcodes = sheet_fillcode_all{si};
            for r = 1:n_rows_data
                code = fillcodes{r};
                if strcmp(code, 'none'), continue; end
                switch code
                    case 'red',    col = red_rgb;
                    case 'orange', col = org_rgb;
                    case 'yellow', col = yel_rgb;
                    otherwise,     col = [];
                end
                if ~isempty(col)
                    ws.Range(ws.Cells(r+1,1), ws.Cells(r+1,n_cols)).Interior.Color = col;
                end
            end
        end

        % Autofit es la opcion mas robusta para anchos de columna -- no
        % hay que adivinar/mantener anchos fijos por hoja a mano.
        ws.Columns.AutoFit();

        ws.Activate();
        ws.Range('A2').Select();
        excelApp.ActiveWindow.FreezePanes = true;
    end

    % Reordenar hojas segun el orden deseado (por si el escritor las dejo
    % en otro orden -- moviendo cada una al final en secuencia, el orden
    % final termina siendo exactamente sheet_names_order).
    for si = 1:numel(sheet_names_order)
        wbCom.Sheets.Item(sheet_names_order{si}).Move([], wbCom.Sheets.Item(wbCom.Sheets.Count));
    end
    wbCom.Sheets.Item(sheet_names_order{1}).Activate();

    wbCom.Save();
end

function rgbval = bgr(r,g,b)
    % Excel/COM empaqueta el color como un entero en orden BGR, no RGB
    rgbval = r + g*256 + b*256*256;
end

function safe_quit_excel(excelApp)
    try, excelApp.Quit(); catch, end
    try, delete(excelApp); catch, end
end

function safe_close_wb(wbCom)
    try, wbCom.Close(false); catch, end
end