-- ATENCION: este script borra TODOS los examenes rendidos (incluidas las notas del parcial).
-- Usarlo solo para limpiar pruebas ANTES de tomar un examen real.

-- =====================================================================
--  LIMPIEZA DESPUÉS DE LAS PRUEBAS
--  Deja el sistema como nuevo para el examen real.
--  Ejecutar en: Supabase → SQL Editor → New query → Run
--
--  SE BORRA:   exámenes rendidos, registro de actividad, alumnos de prueba
--              (los que no están en la lista oficial de 32), últimos ingresos,
--              y el examen vuelve a "no iniciado".
--  SE MANTIENE: la lista de 32 alumnos, las preguntas, la configuración
--              (título, nota de aprobación, etc.) y el usuario de la docente.
-- =====================================================================

begin;

-- 1. Exámenes rendidos (todos)
delete from public.intentos where dni is not null;

-- 2. Alumnos de prueba: todos los que NO están en la lista oficial
delete from public.alumnos
 where dni not in (
   '44665707','44808618','41122715','46259518','42356746','44674997','47286279','47286890',
   '44527396','41809100','45885328','47624865','43764798','46544548','37833864','41468058',
   '39651713','34696729','47046977','31658874','44674995','33236882','47360997','42207419',
   '43952459','47478335','46932470','32624396','47197399','47239296','38078637','40995700');

-- 3. Los 32 alumnos quedan como "No ingresó"
update public.alumnos set ultimo_acceso = null where dni is not null;

-- 4. Registro de actividad de las pruebas
delete from public.registro where id is not null;

-- 5. Examen sin iniciar
update public.config set inicio = null, fin = null where id = 1;

commit;

-- Verificación: debería mostrar 32 alumnos, 0 exámenes, 0 registros y el examen sin iniciar
select (select count(*) from public.alumnos)  as alumnos,
       (select count(*) from public.intentos) as examenes,
       (select count(*) from public.registro) as registros,
       (select inicio from public.config where id = 1) as inicio;
