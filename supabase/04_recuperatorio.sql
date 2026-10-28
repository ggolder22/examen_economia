-- =====================================================================
--  ACTUALIZACIÓN 4 · Varios exámenes (Parcial + Recuperatorio)
--  Ejecutar en: Supabase → SQL Editor → New query → Run
--
--  - Las notas del parcial ya tomado NO se tocan: quedan como examen "parcial".
--  - Se crea el examen "recuperatorio" con 12 preguntas, habilitado solo para:
--      37833864 (Galtian Acuña), 43952459 (Oviedo), 47478335 (Pais)
--  - Queda ACTIVO el recuperatorio, sin iniciar. La docente lo habilita desde el panel.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- ESTRUCTURA
-- ---------------------------------------------------------------------
create table if not exists public.examenes (
  clave       text primary key,
  titulo      text not null,
  habilitados text[]            -- null = todos los alumnos de la lista
);
alter table public.examenes enable row level security;
revoke all on public.examenes from anon, authenticated;

insert into public.examenes (clave, titulo)
select 'parcial', titulo from public.config where id = 1
on conflict (clave) do nothing;

insert into public.examenes (clave, titulo, habilitados)
values ('recuperatorio', 'Examen recuperatorio', array['37833864', '43952459', '47478335'])
on conflict (clave) do update set habilitados = excluded.habilitados;

alter table public.config    add column if not exists examen text not null default 'parcial' references public.examenes(clave);
alter table public.preguntas add column if not exists examen text not null default 'parcial' references public.examenes(clave);
alter table public.intentos  add column if not exists examen text not null default 'parcial' references public.examenes(clave);

-- Un intento por alumno POR EXAMEN
alter table public.intentos drop constraint if exists intentos_pkey;
alter table public.intentos add primary key (examen, dni);

-- ---------------------------------------------------------------------
-- FUNCIONES INTERNAS
-- ---------------------------------------------------------------------
create or replace function public._ex() returns text
language sql stable security definer set search_path = public as $$
  select examen from config where id = 1;
$$;

create or replace function public._habilitado(p_dni text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(habilitados is null or p_dni = any(habilitados), false)
  from examenes where clave = _ex();
$$;

-- Todo lo registrado queda marcado con el examen activo
create or replace function public._log(p_dni text, p_evento text, p_datos jsonb)
returns void language sql security definer set search_path = public as $$
  insert into registro (dni, evento, datos)
  values (p_dni, p_evento, coalesce(p_datos, '{}'::jsonb) || jsonb_build_object('examen', _ex()));
$$;

create or replace function public._merge(p_dni text, p_resp jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_ex text := _ex();
  v_actual  jsonb;
  v_cambios jsonb := '{}'::jsonb;
  k text; v jsonb; n int; num numeric;
begin
  if p_resp is null or jsonb_typeof(p_resp) <> 'object' then return; end if;

  select respuestas into v_actual from intentos
   where examen = v_ex and dni = p_dni and entregado is null for update;
  if not found then return; end if;

  for k, v in select * from jsonb_each(p_resp) loop
    n := null;
    if jsonb_typeof(v) = 'number' then
      num := (v #>> '{}')::numeric;
      select jsonb_array_length(opciones) into n from preguntas where examen = v_ex and id::text = k;
      if n is not null and num = trunc(num) and num between 0 and n - 1
         and (v_actual -> k) is distinct from to_jsonb(num::int) then
        v_cambios := v_cambios || jsonb_build_object(k, num::int);
      end if;
    end if;
  end loop;

  if v_cambios <> '{}'::jsonb then
    update intentos set respuestas = respuestas || v_cambios, actualizado = now()
     where examen = v_ex and dni = p_dni;
    perform _log(p_dni, 'respuesta', v_cambios);
  end if;
end $$;

create or replace function public._calificar(p_dni text, p_auto boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_ex text := _ex();
  v_resp jsonb; v_total int := 0; v_ok int := 0;
  v_det jsonb := '[]'::jsonb; r record; v_elegida int; v_nota numeric;
begin
  select respuestas into v_resp from intentos
   where examen = v_ex and dni = p_dni and entregado is null for update;
  if not found then return; end if;

  for r in select * from preguntas where examen = v_ex order by orden, id loop
    v_total := v_total + 1;
    v_elegida := (v_resp ->> r.id::text)::int;
    if v_elegida is not distinct from r.correcta then v_ok := v_ok + 1; end if;
    v_det := v_det || jsonb_build_array(jsonb_build_object(
      'id', r.id, 'enunciado', r.enunciado, 'opciones', r.opciones,
      'correcta', r.correcta, 'elegida', v_elegida,
      'ok', v_elegida is not distinct from r.correcta,
      'explicacion', r.explicacion));
  end loop;

  v_nota := case when v_total = 0 then 1
                 else greatest(1, round(v_ok * 10.0 / v_total, 1)) end;

  update intentos
     set entregado = now(), entrega_auto = p_auto,
         aciertos = v_ok, total = v_total, nota = v_nota, detalle = v_det
   where examen = v_ex and dni = p_dni;

  perform _log(p_dni, case when p_auto then 'entrega_automatica' else 'entrega' end,
               jsonb_build_object('aciertos', v_ok, 'total', v_total, 'nota', v_nota));
end $$;

create or replace function public._cerrar_vencidos()
returns void language plpgsql security definer set search_path = public as $$
declare r record; v_ex text := _ex();
begin
  if exists (select 1 from config where id = 1 and fin is not null and now() > fin + _gracia())
     and exists (select 1 from intentos where examen = v_ex and entregado is null) then
    perform pg_advisory_xact_lock(424242);
    for r in select dni from intentos where examen = v_ex and entregado is null order by dni loop
      perform _calificar(r.dni, true);
    end loop;
  end if;
end $$;

create or replace function public._resultado(p_dni text)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when c.mostrar_resultado then
           jsonb_build_object('visible', true, 'aciertos', i.aciertos, 'total', i.total,
                              'nota', i.nota, 'aprobado', i.nota >= c.nota_aprobacion,
                              'entregado', i.entregado, 'auto', i.entrega_auto,
                              'detalle', i.detalle)
         else
           jsonb_build_object('visible', false, 'entregado', i.entregado, 'auto', i.entrega_auto)
         end
  from intentos i, config c
  where c.id = 1 and i.examen = c.examen and i.dni = p_dni and i.entregado is not null;
$$;

-- ---------------------------------------------------------------------
-- ALUMNOS
-- ---------------------------------------------------------------------
create or replace function public.alumno_estado(p_token uuid, p_respuestas jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  a alumnos; c config; i intentos; v_estado text; v_tiene boolean; v_preg jsonb; v_ex text;
begin
  select * into a from alumnos where token = p_token;
  if not found then raise exception 'SESION_INVALIDA'; end if;
  update alumnos set ultimo_acceso = now() where dni = a.dni;

  select * into c from config where id = 1;
  v_ex := c.examen;

  if not _habilitado(a.dni) then
    return jsonb_build_object(
      'ahora', now(), 'estado', 'no_habilitado', 'titulo', c.titulo,
      'alumno', jsonb_build_object('dni', a.dni, 'apellido', a.apellido, 'nombre', a.nombre),
      'en_examen', false);
  end if;

  perform _cerrar_vencidos();
  v_estado := _estado();

  select * into i from intentos where examen = v_ex and dni = a.dni;
  v_tiene := found;

  if not v_tiene and v_estado = 'en_curso' then
    insert into intentos (examen, dni) values (v_ex, a.dni) on conflict (examen, dni) do nothing;
    if found then perform _log(a.dni, 'inicio_examen', null); end if;
    select * into i from intentos where examen = v_ex and dni = a.dni;
    v_tiene := true;
  end if;

  if v_tiene and i.entregado is null then
    if p_respuestas is not null and _ventana_abierta() then
      perform _merge(a.dni, p_respuestas);
    end if;
    if v_estado = 'finalizado' then
      perform _calificar(a.dni, true);
    end if;
    select * into i from intentos where examen = v_ex and dni = a.dni;
  end if;

  if v_tiene and i.entregado is null and v_estado = 'en_curso' then
    select coalesce(jsonb_agg(jsonb_build_object('id', id, 'enunciado', enunciado, 'opciones', opciones)
                              order by orden, id), '[]'::jsonb)
      into v_preg from preguntas where examen = v_ex;
  end if;

  return jsonb_build_object(
    'ahora', now(), 'estado', v_estado, 'titulo', c.titulo, 'inicio', c.inicio, 'fin', c.fin,
    'alumno', jsonb_build_object('dni', a.dni, 'apellido', a.apellido, 'nombre', a.nombre),
    'en_examen', coalesce(v_tiene and i.entregado is null and v_estado = 'en_curso', false),
    'respuestas', case when v_tiene then i.respuestas end,
    'preguntas', v_preg,
    'resultado', case when v_tiene and i.entregado is not null then _resultado(a.dni) end
  );
end $$;

create or replace function public.alumno_guardar(p_token uuid, p_respuestas jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a alumnos;
begin
  select * into a from alumnos where token = p_token;
  if not found then raise exception 'SESION_INVALIDA'; end if;
  if not _ventana_abierta()
     or not exists (select 1 from intentos where examen = _ex() and dni = a.dni and entregado is null) then
    raise exception 'EXAMEN_CERRADO';
  end if;
  perform _merge(a.dni, p_respuestas);
  update alumnos set ultimo_acceso = now() where dni = a.dni;
  return jsonb_build_object('ok', true, 'ahora', now(), 'fin', (select fin from config where id = 1));
end $$;

create or replace function public.alumno_entregar(p_token uuid, p_respuestas jsonb, p_auto boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a alumnos; v_abierta boolean;
begin
  select * into a from alumnos where token = p_token;
  if not found then raise exception 'SESION_INVALIDA'; end if;
  if exists (select 1 from intentos where examen = _ex() and dni = a.dni and entregado is null) then
    v_abierta := _ventana_abierta();
    if v_abierta then perform _merge(a.dni, p_respuestas); end if;
    perform _calificar(a.dni, coalesce(p_auto, false) or not v_abierta);
  end if;
  return alumno_estado(p_token, null);
end $$;

-- ---------------------------------------------------------------------
-- DOCENTE
-- ---------------------------------------------------------------------
create or replace function public.admin_estado()
returns jsonb language plpgsql security definer set search_path = public as $$
declare c config; v_alumnos jsonb; v_preg jsonb; v_examenes jsonb; v_hab text[];
begin
  perform _exigir_admin();
  perform _cerrar_vencidos();
  select * into c from config where id = 1;
  select habilitados into v_hab from examenes where clave = c.examen;

  select coalesce(jsonb_agg(jsonb_build_object(
           'nro', a.nro, 'dni', a.dni, 'apellido', a.apellido, 'nombre', a.nombre,
           'creado', a.creado, 'ultimo_acceso', a.ultimo_acceso,
           'habilitado', v_hab is null or a.dni = any(v_hab),
           'tiene_intento', i.dni is not null, 'iniciado', i.iniciado,
           'respondidas', (select count(*) from jsonb_object_keys(coalesce(i.respuestas, '{}'::jsonb))),
           'entregado', i.entregado, 'entrega_auto', i.entrega_auto,
           'aciertos', i.aciertos, 'total', i.total, 'nota', i.nota,
           'notas', (select coalesce(jsonb_object_agg(x.examen, jsonb_build_object(
                        'nota', x.nota, 'entregado', x.entregado, 'aciertos', x.aciertos, 'total', x.total)), '{}'::jsonb)
                       from intentos x where x.dni = a.dni))
         order by a.nro nulls last, a.apellido, a.nombre), '[]'::jsonb)
    into v_alumnos
    from alumnos a left join intentos i on i.dni = a.dni and i.examen = c.examen;

  select coalesce(jsonb_agg(to_jsonb(p) order by p.orden, p.id), '[]'::jsonb)
    into v_preg from preguntas p where p.examen = c.examen;

  select coalesce(jsonb_agg(jsonb_build_object(
           'clave', e.clave, 'titulo', e.titulo, 'habilitados', e.habilitados,
           'preguntas', (select count(*) from preguntas p where p.examen = e.clave),
           'rendidos', (select count(*) from intentos x where x.examen = e.clave and x.entregado is not null))
         order by e.clave = 'recuperatorio', e.clave), '[]'::jsonb)
    into v_examenes from examenes e;

  return jsonb_build_object('ahora', now(), 'estado', _estado(), 'config', to_jsonb(c),
                            'alumnos', v_alumnos, 'preguntas', v_preg, 'examenes', v_examenes);
end $$;

create or replace function public.admin_alumno(p_dni text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform _exigir_admin();
  return jsonb_build_object(
    'alumno',   (select to_jsonb(a) - 'token' from alumnos a where dni = p_dni),
    'intento',  (select to_jsonb(i) from intentos i where examen = _ex() and dni = p_dni),
    'registro', (select coalesce(jsonb_agg(to_jsonb(r) order by r.ts desc), '[]'::jsonb)
                   from (select ts, evento, datos from registro where dni = p_dni
                         order by ts desc limit 300) r));
end $$;

create or replace function public.admin_iniciar(p_minutos int)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _exigir_admin();
  if p_minutos is null or p_minutos < 1 or p_minutos > 600 then
    raise exception 'Indicá una duración entre 1 y 600 minutos.';
  end if;
  if _estado() = 'en_curso' then raise exception 'El examen ya está en curso.'; end if;
  if not exists (select 1 from preguntas where examen = _ex()) then
    raise exception 'Este examen no tiene preguntas cargadas.';
  end if;
  update config set inicio = now(), fin = now() + make_interval(mins => p_minutos),
                    duracion_min = p_minutos where id = 1;
  perform _log(null, 'docente_inicia_examen', jsonb_build_object('minutos', p_minutos));
end $$;

create or replace function public.admin_permitir_nuevo_intento(p_dni text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _exigir_admin();
  perform _log(p_dni, 'docente_borra_intento',
               (select to_jsonb(i) from intentos i where examen = _ex() and dni = p_dni));
  delete from intentos where examen = _ex() and dni = p_dni;
end $$;

create or replace function public.admin_guardar_pregunta(p_id int, p_orden int, p_enunciado text,
                                                         p_opciones jsonb, p_correcta int,
                                                         p_explicacion text)
returns int language plpgsql security definer set search_path = public as $$
declare v_id int;
begin
  perform _exigir_admin();
  if _estado() = 'en_curso' then
    raise exception 'No se pueden modificar preguntas mientras el examen está en curso.';
  end if;
  if coalesce(trim(p_enunciado), '') = '' then raise exception 'Falta el enunciado.'; end if;
  if jsonb_typeof(p_opciones) <> 'array' or jsonb_array_length(p_opciones) < 2 then
    raise exception 'La pregunta necesita al menos 2 opciones.';
  end if;
  if p_correcta is null or p_correcta < 0 or p_correcta >= jsonb_array_length(p_opciones) then
    raise exception 'Marcá cuál es la opción correcta.';
  end if;

  if p_id is null then
    insert into preguntas (examen, orden, enunciado, opciones, correcta, explicacion)
    values (_ex(), coalesce(p_orden, 0), trim(p_enunciado), p_opciones, p_correcta, p_explicacion)
    returning id into v_id;
  else
    update preguntas set orden = coalesce(p_orden, orden), enunciado = trim(p_enunciado),
           opciones = p_opciones, correcta = p_correcta, explicacion = p_explicacion
     where id = p_id and examen = _ex() returning id into v_id;
  end if;
  perform _log(null, 'docente_guarda_pregunta', jsonb_build_object('id', v_id));
  return v_id;
end $$;

create or replace function public.admin_eliminar_pregunta(p_id int)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _exigir_admin();
  if _estado() = 'en_curso' then
    raise exception 'No se pueden modificar preguntas mientras el examen está en curso.';
  end if;
  perform _log(null, 'docente_elimina_pregunta',
               (select to_jsonb(p) from preguntas p where id = p_id and examen = _ex()));
  delete from preguntas where id = p_id and examen = _ex();
end $$;

create or replace function public.admin_config(p_titulo text, p_duracion int,
                                               p_mostrar boolean, p_nota_aprobacion numeric)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _exigir_admin();
  update config set titulo = coalesce(nullif(trim(p_titulo), ''), titulo),
                    duracion_min = coalesce(p_duracion, duracion_min),
                    mostrar_resultado = coalesce(p_mostrar, mostrar_resultado),
                    nota_aprobacion = coalesce(p_nota_aprobacion, nota_aprobacion)
   where id = 1;
  update examenes set titulo = (select titulo from config where id = 1) where clave = _ex();
  perform _log(null, 'docente_configura',
               jsonb_build_object('titulo', p_titulo, 'duracion', p_duracion,
                                  'mostrar', p_mostrar, 'nota_aprobacion', p_nota_aprobacion));
end $$;

-- Borra SOLO los intentos del examen activo (nunca los de otro examen)
create or replace function public.admin_reiniciar(p_borrar_alumnos boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _exigir_admin();
  if _estado() = 'en_curso' then raise exception 'Finalizá el examen antes de borrar.'; end if;
  perform _log(null, 'docente_reinicia_examen', null);
  delete from intentos where examen = _ex();
  update config set inicio = null, fin = null where id = 1;
end $$;

-- Cambia el examen activo (Parcial / Recuperatorio)
create or replace function public.admin_cambiar_examen(p_clave text)
returns void language plpgsql security definer set search_path = public as $$
declare e examenes;
begin
  perform _exigir_admin();
  if _estado() = 'en_curso' then raise exception 'Finalizá el examen en curso antes de cambiar.'; end if;
  select * into e from examenes where clave = p_clave;
  if not found then raise exception 'Ese examen no existe.'; end if;
  update config set examen = e.clave, titulo = e.titulo, inicio = null, fin = null where id = 1;
  perform _log(null, 'docente_cambia_examen', jsonb_build_object('a', p_clave));
end $$;

-- Define qué alumnos pueden rendir el examen activo (null o vacío = todos)
create or replace function public.admin_habilitados(p_dnis text[])
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _exigir_admin();
  update examenes set habilitados = case when p_dnis is null or cardinality(p_dnis) = 0 then null else p_dnis end
   where clave = _ex();
  perform _log(null, 'docente_cambia_habilitados', jsonb_build_object('dnis', p_dnis));
end $$;

-- ---------------------------------------------------------------------
-- PERMISOS
-- ---------------------------------------------------------------------
revoke execute on function public._ex(), public._habilitado(text) from public, anon, authenticated;
revoke execute on function public._log(text, text, jsonb), public._merge(text, jsonb),
  public._calificar(text, boolean), public._cerrar_vencidos(), public._resultado(text)
from public, anon, authenticated;
revoke execute on function public.admin_cambiar_examen(text), public.admin_habilitados(text[]) from public, anon;
grant  execute on function public.admin_cambiar_examen(text), public.admin_habilitados(text[]) to authenticated;

-- ---------------------------------------------------------------------
-- PREGUNTAS DEL RECUPERATORIO (12)
-- ---------------------------------------------------------------------
insert into public.preguntas (examen, orden, enunciado, opciones, correcta, explicacion)
select 'recuperatorio', v.* from (values
  (1, '¿Cuál de los siguientes enunciados corresponde a la economía positiva?',
   '["Si el precio de la carne sube, los consumidores compran menos carne.", "El Estado debería subsidiar el transporte público.", "Las empresas mineras deberían reinvertir sus ganancias en la provincia.", "Es injusto que los alimentos paguen impuestos."]'::jsonb,
   0, 'La economía positiva describe lo que ES, con relaciones que se pueden comprobar. Las demás opciones expresan opiniones sobre lo que DEBERÍA SER (economía normativa).'),
  (2, '¿Cuál de los siguientes temas estudia la microeconomía?',
   '["La tasa de desempleo del país.", "Cómo decide una empresa minera cuántos trabajadores contratar.", "El nivel general de precios (inflación).", "La balanza comercial de la Argentina."]'::jsonb,
   1, 'La microeconomía estudia las decisiones de las unidades individuales: familias, empresas y mercados. Las demás son variables agregadas (macroeconomía).'),
  (3, 'Si los recursos fueran ilimitados:',
   '["Habría más necesidades que recursos para satisfacerlas.", "Los bienes libres pasarían a tener precio.", "No existiría el problema económico, porque no haría falta elegir cómo usarlos.", "Las empresas no podrían producir bienes."]'::jsonb,
   2, 'El problema económico es la escasez. Sin escasez no habría que elegir ni administrar, y la economía perdería su razón de ser.'),
  (4, '¿Cuál de los siguientes es un bien económico?',
   '["El aire de la atmósfera.", "La luz solar.", "El agua de lluvia en el campo.", "Una netbook."]'::jsonb,
   3, 'Un bien económico es escaso, requiere trabajo y recursos para producirse y tiene precio. Los demás son bienes libres.'),
  (5, 'Un sistema basado en la propiedad pública de los recursos, la planificación de la economía y el reparto igualitario de la riqueza corresponde al:',
   '["Modelo socialista.", "Modelo capitalista.", "Sistema de economía mixta.", "Sistema de libre mercado."]'::jsonb,
   0, 'El modelo socialista defiende la propiedad pública, la planificación y la búsqueda de la justicia social.'),
  (6, 'En la función Y = f(X):',
   '["La variable Y depende de la variable X.", "La variable X depende de la variable Y.", "La variable Y depende de f.", "Todas las demás respuestas son correctas.", "Ninguna respuesta es correcta."]'::jsonb,
   0, 'Y = f(X) se lee "Y es función de X": el valor de Y depende del valor que tome X. La f solo indica que hay una relación entre ellas; no es una variable.'),
  (7, '¿Cuál de las siguientes es una variable flujo?',
   '["Las 18.000 toneladas de mineral en depósito al 31 de agosto.", "El valor de las maquinarias al 31 de diciembre.", "Las 12.000 toneladas de mineral vendidas durante agosto.", "El inventario de mineral al 30 de junio."]'::jsonb,
   2, 'Una variable flujo se mide a lo largo de un período (durante agosto). Las demás se miden en un momento determinado: son variables stock.'),
  (8, 'El PBI (Producto Bruto Interno) es:',
   '["La suma de todas las ventas de todas las empresas, incluidos los insumos intermedios.", "El dinero que tiene el Estado en el Banco Central.", "La cantidad de personas que trabajan en un país.", "El valor de los bienes y servicios finales producidos dentro de un país durante un período determinado."]'::jsonb,
   3, 'El PBI mide el valor de la producción final realizada dentro del país en un período. No suma todas las ventas, para no contar dos veces los mismos bienes.'),
  (9, 'Una economía tiene: consumo (C) = 500, inversión (I) = 150, gasto público (G) = 200, exportaciones (X) = 120 e importaciones (M) = 70, en millones. Según PBI = C + I + G + (X − M), ¿cuál es el PBI?',
   '["900 millones.", "1.040 millones.", "970 millones.", "830 millones."]'::jsonb,
   0, 'PBI = 500 + 150 + 200 + (120 − 70) = 850 + 50 = 900 millones. Las importaciones se restan.'),
  (10, '¿En qué fase del ciclo económico suelen disminuir la producción, la inversión y el empleo?',
   '["Expansión.", "Recesión o contracción.", "Auge o pico.", "Recuperación."]'::jsonb,
   1, 'En la recesión o contracción disminuye la actividad económica: pueden caer la producción, la inversión y el empleo.'),
  (11, 'Un trabajador minero cobraba $800.000 con un índice de precios de 100. Al año siguiente cobra $960.000 y el índice de precios es 120. ¿Qué pasó con su salario real?',
   '["Aumentó un 20%.", "Disminuyó un 20%.", "Se mantuvo igual: en ambos años equivale a $800.000 a precios del año base.", "Aumentó $160.000."]'::jsonb,
   2, 'Salario real = salario nominal ÷ índice de precios × 100. Año 1: 800.000 ÷ 100 × 100 = 800.000. Año 2: 960.000 ÷ 120 × 100 = 800.000. El poder adquisitivo no cambió.'),
  (12, 'Si en un año la inflación es mayor que el aumento de los salarios nominales:',
   '["El salario real aumenta.", "El PBI necesariamente disminuye.", "El salario nominal disminuye.", "El salario real disminuye, aunque el PBI pueda estar creciendo."]'::jsonb,
   3, 'Si los precios suben más que los salarios, los trabajadores pueden comprar menos: cae el salario real. Esto puede ocurrir aunque el PBI crezca.')
) as v(orden, enunciado, opciones, correcta, explicacion)
where not exists (select 1 from public.preguntas where examen = 'recuperatorio');

-- ---------------------------------------------------------------------
-- DEJAR ACTIVO EL RECUPERATORIO (sin iniciar)
-- ---------------------------------------------------------------------
update public.config
   set examen = 'recuperatorio', titulo = 'Examen recuperatorio', inicio = null, fin = null
 where id = 1 and (inicio is null or now() >= fin);

commit;

-- Verificación
select e.clave, e.titulo, e.habilitados,
       (select count(*) from public.preguntas p where p.examen = e.clave) as preguntas,
       (select count(*) from public.intentos i where i.examen = e.clave and i.entregado is not null) as rendidos,
       (select examen from public.config) as activo
from public.examenes e order by e.clave;
