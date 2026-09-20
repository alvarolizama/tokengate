# DESIGN.md — sistema de UI

Estándar de interfaz de la familia de apps que comparten un **mismo lenguaje
visual**. Este documento es el **Commons** — la base compartida: tema y tokens,
layout, elementos básicos, composición, estados, convenciones y shell.

**Cómo se usa:**

- Cada app **copia este archivo tal cual** a la raíz de su repo como su
  `DESIGN.md` y **añade al final** su sección `## Custom — <App>` con lo
  exclusivo de esa app.
- El Commons **no se edita** en los repos de las apps: se cambia **aquí** y se
  propaga copiándolo. Si cambias algo aquí, cámbialo en todos los `DESIGN.md`.

**Criterio de reparto:** todo lo que se pueda compartir vive en **Commons**
(tema y marca, layout y responsive, shell/sidebar/menús, elementos y **botones
por contexto**, cards, tablas, modales, buscadores, gráficas, estados). Custom
es la excepción y cada bloque suyo dice **por qué** no es compartible (marca la
diferencia real, no el gusto). Si dudas, va a Commons.

> **Regla de oro de este doc: refleja el código.** Todo lo que se afirma aquí
> debe poder señalarse en `lib/<app>_web/…` o `assets/css/app.css`. Si el
> código cambia, este archivo cambia con él.

---

## C1. Principios

1. **daisyUI nativo + Tailwind.** No inventes componentes si daisyUI ya trae
   (`btn`, `card`, `table`, `badge`, `input`, `select`, `alert`, `modal`,
   `dropdown`, `tabs`). CSS propio sólo para convenciones **globales**.
2. **Un solo tema por app, elegido en `app.css`.** La familia corre daisyUI
   **`dim --default`**, declarado en `app.css` y `data-theme` de
   `root.html.heex`; los valores concretos del tema en uso están en el
   **Apéndice A**. Nada de hex/oklch hardcodeado en plantillas: siempre las
   vars del tema.
3. **Reusar antes de crear.** Mira `*Web.CoreComponents` antes de escribir
   markup a mano: inputs, tablas, headers, iconos ya están.
4. **Verificable.** Todo control interactivo lleva `id` estable para tests
   (`has_element?/2`).

## C2. Tema y tokens

```css
/* assets/css/app.css */
@plugin "../vendor/heroicons";
@plugin "../vendor/daisyui" {
  themes: dim --default;   /* ← tema ÚNICO de la familia (valores en el Apéndice A) */
}
```

```heex
<%!-- lib/<app>_web/components/layouts/root.html.heex --%>
<html data-theme="dim">
```

**Regla del scaffold:** si `app.css` venía con `themes: false` + bloques
`@plugin "../vendor/daisyui-theme"`, hay que **borrar** esos bloques (y el JS
del switcher de tema en `root.html.heex`) al fijar el tema built-in, o el tema
viejo queda pegado.

Colores semánticos (usar SIEMPRE las vars, nunca hex/oklch a mano):

| Rol | Utility daisyUI | Var | Uso |
|---|---|---|---|
| Fondo app | `bg-base-100` | `--color-base-100` | superficie base |
| Superficie 2 | `bg-base-200` | `--color-base-200` | paneles, hover de fila |
| Superficie 3 | `bg-base-300` | `--color-base-300` | bordes, chips |
| Texto | `text-base-content` | `--color-base-content` | + `/50` `/40` para secundario |
| Primario | `btn-primary`, `text-primary` | `--color-primary` | acción principal, links |
| Secundario | `btn-secondary` | `--color-secondary` | acento de marca |
| Acento | `btn-accent` | `--color-accent` | "extra" / activo no primario |
| Neutro | `badge-ghost` | `--color-neutral` | global / sin estado |
| Éxito | `badge-success` | `--color-success` | ok, activo |
| Aviso | `badge-warning` | `--color-warning` | warning / aviso |
| Error | `badge-error`, `text-error` | `--color-error` | destructivo |
| Info | `badge-info` | `--color-info` | informativo |

Radios y bordes salen del tema (`--radius-box`, `--radius-field`, `--border`).
No los hardcodees.

**El tema manda.** Todos los colores de la app —incluidos los del **logo del
tema** (favicon/iconos que sigan el tema) y los de gráficas— salen de los
tokens daisyUI del tema declarado en `app.css`; ninguna vista escribe
hex/oklch. Cambiar de tema = cambiar **una línea** (`themes: <tema>
--default`) + `data-theme` en `root.html.heex`: las vistas no se tocan. Los
valores concretos del tema en uso están en el **Apéndice A**. La única
excepción son los colores de la **marca** (§C2.1), que no siguen el tema.

### C2.1 Marca (logo y favicon)

El mark de cada app es **de la familia** y no sigue el primary del tema: usa
los colores de marca en un gradiente `#9fe88d → #62efbd` (trazos) con nodos
`#9fe88d` / `#62efbd` / `#6fbb5c` y core `#c9f7be`. Van juntos en el mismo
commit: `priv/static/favicon.svg` (fuente), `logo.png` (512 con alpha) y
`favicon.ico` (16/32/48). Si el tema cambia, el mark **no** se recolorea: el
verde de la familia es lo que hace reconocible la app.

## C3. Layout base

- El contenido principal va en un `<main>`; el **shell** (sidebar, gaveta,
  rail) es familia → **§C12** (cada app declara sólo sus secciones y
  opciones).
- **Header de página:** `<.header>` — título (`:inner_block`) + `:subtitle` +
  `:actions`.
- **Filtros y acciones, alineados a la DERECHA** (slot `:actions` o
  `justify-end`). Nunca a la izquierda.
- **Contenedores anchos** (tablas/paneles) envueltos en `overflow-x-auto`.

### C3.1 Responsive (mobile-first)

Toda superficie nueva nace usable en teléfono; el escritorio es la mejora, no
el punto de partida.

| Regla | Cómo |
|---|---|
| **Corte del shell** | **`lg` (64rem)**: debajo, la navegación va en **gaveta** (overlay + hamburguesa); arriba, fija y colapsable a **rail** de iconos (§C12) |
| **Padding del contenido** | `p-4 pb-16 sm:p-6` — en móvil más ajustado |
| **Headers de página** | `flex flex-wrap items-center justify-between gap-3`: las acciones bajan de línea en pantallas chicas |
| **Tablas** | siempre `overflow-x-auto` (§C6): scrollean en horizontal, nunca rompen el layout |
| **Grids** | mobile-first: `grid-cols-1 sm:grid-cols-2 lg:grid-cols-3`; **nunca** arrancar en 2+ columnas |
| **Anchos** | `w-full min-w-0`; los `max-w-*` son para modales y textos, no para el contenido |
| **Modales** | overlay `p-4` + card `w-full max-w-*`; las columnas de metadata van `hidden md:flex` (§C7.2) |
| **Texto** | sin truncados duros fuera de tablas/celdas; lo truncado lleva `title` |
| **Acciones** | `btn-xs`+ (target táctil); las de fila conservan `title` (§C6) |

## C4. Elementos básicos

Los controles primitivos. Todo lo demás (cards, tablas, modales, pickers) se
compone de esto.

| Elemento | Clase estándar |
|---|---|
| Botón primario | `btn btn-primary` (o `<.button variant="primary">`) |
| Botón secundario | `btn btn-primary btn-soft` (default de `<.button>`) |
| Botón neutro / cancelar | `btn btn-ghost` |
| Acción de fila | `btn btn-xs btn-ghost` (+ `title=`) |
| Destructivo | `btn ... text-error` + `data-confirm="…"` |
| Badge | `badge badge-sm` + semántico (`badge-primary/success/warning/error/info/ghost/outline/accent`) |
| Chip removible | `badge badge-sm` con `<button>` interno |
| Input de texto | `<.input field={@form[:x]} />` (nunca `<input>` a mano) |
| Icono | `<.icon name="hero-…" class="size-4" />` (heroicons, NO SVG suelto) |
| Toast (flash) | `toast toast-top toast-end z-50` + `alert alert-info/alert-error` |

**Todo pasa por `CoreComponents`** — no armes el `<input>` ni el flash a mano:

- `flash` · `button` (con `variant="primary" | nil`) · `input` · `header` ·
  `table` · `list` · `icon` · `show`/`hide` · `translate_error`/`translate_errors`.

**Primitivas de navegación y superficie** (también en `CoreComponents`, para
que cualquier LiveView las tenga por `use <App>Web, :html`, sin imports):

| Componente | Qué es | Atributos |
|---|---|---|
| `<.nav_link>` | enlace de sidebar/rail: icono + label + badge | `label` · `icon` · `path` · `active` · `badge` |
| `<.nav_group>` | rótulo de grupo + sus enlaces | `label` + slot |
| `<.menu_item>` | entrada de menú (dropdown, menú de usuario) | `href` · `icon` · `label` · `active` |
| `<.section>` | sección: caja con header (badge + título + caption) | `title` · `icon` · `caption` + slot |
| `<.modal>` | modal compacto (C7.1): ✕ / Escape / click-away | `id` · `title` · `on_close` · `max_w` + slot (el caller lo gatea con `:if`) |
| `<.empty_state>` | estado vacío canónico (C6) | `icon` · `title` · `caption` · `class` + slot CTA |

Nacieron en admin/settings y en el shell y se promovieron a `CoreComponents`
para que no exista una segunda copia: si una pantalla necesita un enlace de
nav, una sección, un modal o un estado vacío, **usa el componente
compartido** — no escribas markup nuevo ni un helper local.

### C4.1 Botones por contexto

El mismo `btn` cambia de forma según dónde viva; no hay un "botón estándar"
único:

| Contexto | Forma |
|---|---|
| **CTA de la página (crear)** | `<.button phx-click="new_x" id="new-x-btn">` + icono `hero-plus` (default = `btn-primary btn-soft`); id kebab `new-*-btn` = ancla de tests |
| **Submit de un form** | `<button type="submit" class="btn btn-primary btn-sm">` (sólido: ahí el sólido ES el CTA del formulario) |
| **Cancelar / cerrar** | `btn btn-ghost btn-sm` |
| **Acción de fila** | `btn btn-xs btn-ghost` + `title` (§C6) |
| **Destructivo** | `btn … text-error` + `data-confirm="¿…? Esta acción no se puede deshacer."` |
| **Toggle de filtro / periodo** | `btn-ghost`; activo `btn-primary` |
| **Otra vía** (login social) | `btn btn-outline` |
| **Navegación** | `<.nav_link>` (§C12.3) |

**`btn-outline` es legítimo para "otra vía"** — misma jerarquía que el
primario, camino alternativo (p. ej. "Continuar con Google"), no una variante
de color.

## C5. Tarjetas (cards)

Una sola forma de "caja" en toda la familia.

```heex
<div class="card bg-base-100 border border-base-300 shadow-sm">
  <div class="card-body p-4">
    <h2 class="card-title text-base">
      <.icon name="hero-…" class="size-5 text-base-content/60" />
      Título
    </h2>
    …
  </div>
</div>
```

- **Base:** `card bg-base-100 border border-base-300 shadow-sm` + `card-body`.
- **Densidad del `card-body`** (elegir según el contenido): `p-4` (denso: listas,
  KPIs) · `p-5` (medio) · `p-6` (forms) · `p-8` (hero).
- **Título:** `card-title text-base` + icono `size-5 text-base-content/60`.
- **Card interactiva (clicable):** `hover:shadow-md transition-shadow`.
- **Card de sección con header** (badge de icono + título + caption): cada app
  define su caja de sección en **Custom**.
- **Card de modal:** `shadow-xl` en vez de `shadow-sm` (ver C7).
- Sombras y radios del tema (`--radius-box`, `shadow-sm/md/xl`); no a mano.

**La misma card según dónde esté:**

| Lugar | Forma |
|---|---|
| Página / sección con header | la caja de sección de cada app (badge de icono + título + caption; ver **Custom**) |
| Contenedora de tabla | `card` + `overflow-x-auto` (§C6) |
| Lista / filas | `card-body p-4` denso, hover de fila, sin zebra |
| KPI / stat | `card-body p-4`, número `text-2xl font-semibold`, label secundario |
| Modal | `shadow-xl` + `card-body p-6` (§C7) |
| Estado vacío | `card` centrada con `<.empty_state>` (§C10) |

## C6. Tablas

Estructura canónica (una sola forma en toda la familia):

```heex
<div class="overflow-x-auto card bg-base-100 border border-base-300 shadow-sm">
  <table class="table table-sm">
    <thead>
      <tr>
        <th>…</th>
        <th class="text-right">Acciones</th>
      </tr>
    </thead>
    <tbody id="things" phx-update="stream">
      <tr :for={{id, t} <- @streams.things} id={id}>
        <td>…</td>
        <td class="text-right">
          <button phx-click="edit" phx-value-id={t.id} class="btn btn-xs btn-ghost" title="Editar">
            <.icon name="hero-pencil" class="size-3.5" />
          </button>
        </td>
      </tr>
    </tbody>
  </table>
</div>
```

Reglas:

- **`table table-sm` siempre.** Envuelta en `overflow-x-auto` + card. Columnas de
  ancho fijo: `table table-sm table-fixed w-full`.
- **Hover de fila, sin zebra** — regla global, una vez por app:
  ```css
  .table tbody tr { transition: background-color 150ms ease; }
  .table tbody tr:hover { background-color: color-mix(in oklab, var(--color-base-200) 60%, transparent); }
  ```
- **Colecciones con `stream` + `phx-update="stream"`** (nunca listas grandes
  asignadas). El `id` de cada fila es el del item.
- **Columna de acciones** al final, `btn-xs btn-ghost` con `title`.
- **Empty state** (fuera de la tabla):
  ```heex
  <div :if={@things_empty?} class="text-center py-12 text-base-content/40">
    <.icon name="hero-…" class="size-10 mx-auto mb-2 opacity-40" />
    <p>No hay … todavía.</p>
  </div>
  ```
- **Datos crudos nunca en pantalla:** formatters propios (fechas, precios), nunca
  `Decimal` crudo.

## C7. Modales

Patrón estándar = overlay `div`, **no `<dialog>`**. Cerrar = volver el assign.

### C7.1 Modal simple (una columna)

```heex
<div :if={@show_modal?} class="fixed inset-0 z-50 flex items-center justify-center p-4" id="thing-modal">
  <div class="absolute inset-0 bg-black/50" phx-click="cancel_form" />

  <div class="relative card bg-base-100 border border-base-300 shadow-xl w-full max-w-2xl">
    <div class="card-body p-6">
      <h2 class="text-lg font-semibold mb-4">Nuevo …</h2>
      <.form for={@form} id="thing-form" phx-submit="save">
        …
        <div class="flex gap-2 mt-6 justify-end">
          <button type="button" phx-click="cancel_form" class="btn btn-ghost btn-sm">Cancelar</button>
          <button type="submit" class="btn btn-primary btn-sm" id="save-thing">Guardar</button>
        </div>
      </.form>
    </div>
  </div>
</div>
```

### C7.2 Modal de dos columnas (contenido + sidebar de metadata)

Para forms grandes (crear/editar un recurso): header (pill + título + ✕),
**cuerpo a dos columnas** — contenido principal + `<aside>` de metadata
(`w-80 lg:w-96`, `hidden md:flex`, scroll propio) — y footer. Casi full-screen.

```heex
<div :if={@show_modal?} id="thing-modal-overlay"
     class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4 sm:p-6"
     phx-window-keydown="cancel_form" phx-key="Escape">
  <div id="thing-modal" role="dialog" aria-modal="true" phx-click-away="cancel_form"
       class="card bg-base-100 border border-base-300 shadow-2xl w-full flex flex-col overflow-hidden
              h-[calc(100vh-3rem)] sm:h-[calc(100vh-4rem)] max-w-5xl">
    <%!-- Header --%>
    <div class="flex items-center justify-between px-5 py-3.5 border-b border-base-300 shrink-0">
      <div class="flex items-center gap-2.5 min-w-0">
        <span class="text-[11px] font-semibold px-2 py-0.5 rounded-full shrink-0 bg-primary/10 text-primary">Recurso</span>
        <h3 class="text-base font-semibold truncate">Nueva …</h3>
      </div>
      <button type="button" phx-click="cancel_form" class="btn btn-ghost btn-xs btn-circle" aria-label="Cerrar">
        <.icon name="hero-x-mark" class="size-4" />
      </button>
    </div>

    <%!-- Body: contenido + sidebar --%>
    <div class="flex-1 min-h-0 flex overflow-hidden">
      <div class="flex-1 min-w-0 overflow-y-auto p-6">
        <.form for={@form} id="thing-form" phx-submit="save">…</.form>
      </div>
      <aside class="hidden md:flex md:flex-col w-80 lg:w-96 shrink-0 border-l border-base-300 bg-base-200/40 overflow-y-auto p-5 gap-4">
        <h4 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">Detalles</h4>
        …
      </aside>
    </div>

    <%!-- Footer --%>
    <div class="flex items-center justify-between px-5 py-3 border-t border-base-300 shrink-0">
      <div class="flex items-center gap-2">{render_slot(@left)}</div>
      <div class="flex items-center gap-2">
        <button type="button" phx-click="cancel_form" class="btn btn-ghost btn-sm">Cancelar</button>
        <button type="submit" form="thing-form" class="btn btn-primary btn-sm">Guardar</button>
      </div>
    </div>
  </div>
</div>
```

- El botón **Guardar vive FUERA del `<form>`** (footer) y lo apunta con el
  atributo HTML `form="thing-form"` → el `id` debe coincidir con el del `<.form>`.
- La **sidebar de metadata** va `hidden md:flex` (oculta en móvil) y scrollea
  independiente (`overflow-y-auto`).

Reglas (ambos):

- **Visible sólo cuando el assign existe** (`:if={@form != nil}` / `@show_modal?`).
- **Cierre por backdrop `phx-click` + Escape**
  (`phx-window-keydown` + `phx-key="Escape"`).
- **Anchos:** `max-w-md` (confirmaciones) · `max-w-lg` · `max-w-2xl` (forms) ·
  `max-w-5xl` (modales de dos columnas).
- **Confirmaciones destructivas:** `data-confirm="¿…? Esta acción no se puede deshacer."`
  en el botón.
- **El verbo dice lo que hace el botón, no el color:** un cierre ("Cancelar",
  "← Volver") no viaja en la fila del CTA, y una unión de recurso no se rotula
  "Crear". El par primario/secundario expresa jerarquía; el label, la acción.

## C8. Buscadores y selects

Elige el control por la matriz: ¿cuántos valores? × ¿la lista es grande (necesita buscar)?

| | **1 valor** | **N valores** |
|---|---|---|
| **Pocos** (≤ ~10, sin scroll) | **C8.1 select** | **C8.5 badges toggleables** |
| **Muchos** (buscar) | **C8.3 combobox single** | **C8.4 combobox multi** |

Para texto libre con sugerencias (catálogo largo, valor custom): **C8.2 datalist**.

### C8.1 Select simple (1 valor, sin buscar)

`<.input type="select" options={…} prompt="…" />` — el `<select>` nativo
(`w-full select`). Para un select suelto fuera de un form:
`<select class="select select-bordered select-sm w-full">`.

```heex
<.input field={@form[:owner_id]} type="select" prompt="Elige…" options={@owner_options} />
```

### C8.2 Datalist (texto libre + sugerencias)

`<.input type="datalist" options={…} />` — input de texto con `<datalist>`: el
usuario elige de la lista **o** escribe cualquier valor.

```heex
<.input field={@form[:model]} type="datalist" label="Modelo" options={@catalog} />
```

### C8.3 Combobox single (1 valor, con buscar)

Asigns: `<kind>_search` (texto), `<kind>_open` (bool), `current_<kind>_id`
(elegido). El pick **refleja el label y cierra**.

```heex
<div class="relative" phx-click-away="close_pickers">
  <input type="text" name="thing[owner_id_display]" value={@owner_search}
    phx-focus="open_picker" phx-value-picker="owner"
    phx-change="owner_search" phx-debounce="200"
    autocomplete="off" placeholder="Buscar…" class="input input-sm w-full" />
  <div :if={@owner_open and @owner_results != []}
       class="absolute z-50 left-0 right-0 mt-1 bg-base-100 border border-base-300 rounded-lg shadow-lg max-h-60 overflow-y-auto">
    <button :for={o <- @owner_results} type="button"
      phx-click="select_owner_item" phx-value-id={o.id} phx-value-label={o.label}
      class="block w-full text-left px-3 py-2 hover:bg-primary/10 transition-colors">
      {o.label}
    </button>
  </div>
</div>
```

### C8.4 Combobox multi (N valores, con buscar)

Igual que el single, pero el pick **NO cierra** y **acumula** ids
(`current_<kind>_ids`); los elegidos se muestran como **chips** debajo del input
(cada chip con su `<button>`/icono de quitar) y `✓` en la fila activa.

```heex
<div :if={@current_owner_ids != []} class="flex flex-wrap gap-1 mt-2">
  <span :for={id <- @current_owner_ids}
    class="badge badge-sm badge-primary gap-1 cursor-pointer"
    phx-click="toggle_owner" phx-value-id={id}>
    {label_for(id)} <.icon name="hero-x-mark" class="size-3" />
  </span>
</div>
```

### C8.5 Badges toggleables (N valores, sin buscar)

Para listas cortas (permisos): botones `badge` que alternan. Estado: seleccionado =
`badge-primary` (`badge-accent` para "extra"); libre = `badge-outline` + hover.

```heex
<button :for={m <- @models} type="button"
  phx-click="toggle_model" phx-value-id={m.id}
  class={["badge badge-sm transition-all",
          m.id in @granted_ids && "badge-primary",
          m.id not in @granted_ids && "badge-outline cursor-pointer hover:badge-primary/50"]}>
  {m.name}
</button>
```

### Reglas duras de los combobox (vienen de bugs reales)

1. **El input SIEMPRE va nombrado** (`name="…"`). Sin `name`, dentro de un form,
   LiveView serializa payload vacío en `phx-change` y la búsqueda se borra en
   cada tecla.
2. El handler de búsqueda acepta **ambas formas** del payload (`%{"value" => q}`
   y la anidada `%{ns: %{campo => q}}`) — resolver con cláusulas.
3. **Pick single = reflejar label + cerrar.** **Pick multi = acumular + quedar abierto.**
4. **`phx-click-away` en el wrapper** + `Escape` a nivel form. Nunca dejar el
   dropdown "zombie" abierto.
5. **No** uses `phx-keyup` para filtrar (reabre al soltar Escape). `phx-change` +
   `phx-debounce` (`200` buscar · `300` autocomplete).

## C9. Gráficas (charts)

**No hay librería de gráficas.** En la familia las gráficas son **SVG escritas a
mano en HEEx** (o barras con `style="height: …%"`); los datos se **preprocesan en
Elixir** y las escalas se calculan en el **servidor**.

```heex
<%!-- Bar chart canónico: card + svg --%>
<div id="usage-chart" class="card bg-base-100 border border-base-300 shadow-sm">
  <div class="card-body">
    <h2 class="card-title text-base">
      <.icon name="hero-chart-bar" class="size-5 text-base-content/60" /> Uso
    </h2>
    <div :if={@series == []} class="h-40 flex items-center justify-center text-base-content/40 text-sm">
      Sin datos
    </div>
    <div :else class="flex">
      <div class="flex flex-col justify-between text-[10px] text-base-content/50 pr-1 h-40 text-right w-8">
        <span :for={l <- @y_labels}>{l}</span>
      </div>
      <svg viewBox="0 0 400 150" class="flex-1 h-40" preserveAspectRatio="none">
        <rect :for={{row, i} <- Enum.with_index(@series)} x={10 + i * (@bar_width + 4)}
              y={140 - max(row.value / @max_value * 120, 1)} width={@bar_width}
              height={max(row.value / @max_value * 120, 1)} rx="2" class="fill-primary transition-colors">
          <title>{row.label} — {row.tooltip}</title>
        </rect>
        <line x1="10" y1="140" x2="390" y2="140" class="stroke-base-300" stroke-width="1" />
      </svg>
    </div>
  </div>
</div>
```

Reglas:

- **Sin dependencias JS de charts** (nada de apexcharts/echarts/chart.js/d3).
- **Escalas en el servidor:** helpers Elixir (p. ej. escala `sqrt` con mínimo 4%
  para barras; escala lineal para el sparkline). El template sólo pinta.
- **Contenedor:** SVG con `viewBox` + `preserveAspectRatio="none"` y altura fija
  (`h-40`, `h-8`); o barras con `style="height: …%"` dentro de altura fija.
- **Color de serie:** de una paleta **nombrada** definida en la app (un mapa de
  constantes con nombre, nunca el hex repetido en el call site). Si el color
  identifica un tipo de dato, viaja en el dato del tipo — no en una tabla de
  casos por slug.
- **Ejes y labels:** `text-[10px]`/`text-xs`, `text-base-content/40-50`,
  `tabular-nums` en los valores.
- **Tooltip:** `<title>` dentro del nodo SVG (o `title=` en la barra).
- **Empty state:** contenedor de la misma altura con texto centrado
  (`text-base-content/40`).
- **Sparkline:** `<svg viewBox="0 0 200 30">` + `<polyline points=… fill="none"
  stroke="currentColor" class="text-primary/40" stroke-width="1.5">`.
- **Hover:** realce sutil (`group-hover:brightness-110`), sin re-render.

## C10. Estados

| Estado | Estándar |
|---|---|
| Loading | `.skeleton` (shimmer) o `loading loading-spinner` |
| Empty | icono + texto centrado (`text-base-content/40`) |
| Error | `text-error` inline, o `alert alert-error` |
| Éxito | flash `alert-info` (toast top-end) |

## C11. Convenciones

- **`id` estable** en todo control clave (forms, botones, filas) → `has_element?/2`.
  Form: `id="thing-form"`; fila: `id={id}` (del stream). **El `id` es la
  convención primaria de toda la familia.**
- **`data-testid` sólo donde no hay id natural:** contenedores y estados sin
  `<form>`/fila/stream detrás. `kebab-case`, la parte variable al final tras un
  guion, y nunca como sustituto de un `id` que ya existe. **Todo testid nuevo
  nace con su consumidor en `test/`**: un testid que ningún test lee es ruido.
- **Assigns por picker:** `<kind>_search` / `<kind>_open` / `current_<kind>_id(s)`.
- **Filtros** alineados a la **derecha** del header, siempre.
- **Modales** = overlay div; cierre por assign.
- **Datos crudos nunca en pantalla:** formatters.
- **Tema:** sólo vars del tema; cero hex/oklch hardcodeado (en HEEx y en los
  hooks JS: usar `cssColor("--color-…", fallback)`, nunca hex fijo).
- **i18n:** `Gettext`.
- El gate de una app es **`mix precommit`** (alias en `mix.exs`).

## C12. Shell (sidebar, navegación y menús)

El shell de la familia es **sidebar + barra de contenido** (sin topbar de
escritorio). Cada app declara sus secciones y opciones en **Custom**; la
mecánica es esta.

### C12.1 Estructura

- Raíz `h-screen` + **daisyUI `drawer lg:drawer-open lg:grid-rows-1 h-full`**. Las
  **dos** clases `lg:` son estructurales: la de la fila tiene su propia regla
  dura en **§C12.5** (sin ella el shell scrollea entero).
- **Barra del contenido (`h-14`), siempre visible: es el ÚNICO sitio del toggle
  de navegación.** En `< lg` es la hamburguesa (`label for="app-drawer"`) que
  abre la gaveta; en `≥ lg`, el mismo botón en la misma posición
  colapsa/expande la sidebar (`label for="sidebar-collapse"`). **Nunca dos
  controles**: el sidebar no lleva chevron propio.
- **Móvil (`< lg`):** la sidebar vive en la gaveta (`drawer-side` +
  `drawer-overlay`); cerrar = overlay o navegar. La gaveta no se persiste.
- **Desktop (`≥ lg`):** sidebar fija, **colapsable a rail de iconos** (4rem) con
  el checkbox `#sidebar-collapse` (hermano del `.drawer`): se angosta, los
  textos con `.shell-hide` desaparecen (marca, selector, buscador, labels de
  enlaces y grupos, badges, nombre/email) y quedan **logo + iconos** centrados
  con `title` (tooltip). **No** se oculta la sidebar ni se usa botón flotante:
  un `fixed` tapa el título de la página. En el rail el menú de usuario abre
  hacia la derecha y el `.drawer-side` pierde el recorte (`overflow: visible`) —
  el scroll lo lleva el `<nav>` interno del aside.
- Sidebar `w-60 shrink-0 border-r border-base-300 bg-base-200/50 flex flex-col`.
  Densidad: header `p-3`, búsqueda `p-3`, nav `flex-1 overflow-y-auto p-2 flex
  flex-col gap-4`, pie `p-3 border-t`.

### C12.2 Anatomía de la sidebar

| Zona | Contenido |
|---|---|
| header | logo + wordmark · selector de contexto (`select select-xs`) |
| búsqueda | form GET del contexto con hint `⌘K` |
| nav | entradas siempre visibles + grupos (`<.nav_group>`) |
| pie | `<.user_footer>`: avatar + nombre/email + menú |

### C12.3 Navegación y menús

- **`<.nav_link>`**: `btn btn-sm w-full justify-between font-normal`; inactivo
  `btn-ghost text-base-content/80`; **activo `bg-primary/15 text-primary
  font-medium hover:bg-primary/20` + `aria-current="page"`**. **No** usar
  `btn-primary btn-soft` para el activo: mezcla sólo 8% del color con `base-100`
  y el pill se lee gris. Badge `badge badge-sm` (ghost; primary si activo).
  `title` con el label — es el tooltip del rail.
- **`<.nav_group>`**: rótulo `text-xs font-semibold uppercase tracking-wider
  text-base-content/70`, `px-3 pt-1 pb-1`; grupos con `gap-4`, links con `gap-1`.
- **Menú de usuario** (`#user-menu`, `<.menu_item>`), anclado abajo-izquierda:
  **Workspaces** (→ `/`, siempre: es la vuelta al listado desde cualquier URL) ·
  Profile · API keys · *(divider, sólo con contexto)* entradas del contexto ·
  *(divider)* Log out. El entry activo: `aria-current="page"` + `text-primary`.
- **Sin navegación duplicada:** si el sidebar ya lleva a una sección, la página
  no la repite adentro; las acciones de contexto van en el menú de usuario, no
  en el nav. La identidad de una página la dan su `<h1>` + caption.

### C12.4 Padding del contenido

Lo pone el layout: `p-4 pb-16 sm:p-6`. El `pb-16` es el aire final del scroll
(la última card nunca queda pegada al borde). Nunca dejar el contenido sin
padding.

### C12.5 Reglas duras del shell (vienen de bugs reales)

1. **La fila del `.drawer` va acotada: `lg:grid-rows-1`.** El `drawer` de daisyUI
   es un grid y declara **sólo `grid-auto-columns`**: la fila queda **implícita**
   y su alto lo decide `grid-auto-rows` (default `auto`), así que **se infla con
   el contenido de la página**. Con contenido largo scrollea el shell ENTERO — la
   barra del contenido y la sidebar se van con la rueda, y `main` se queda sin
   scroll propio — en lugar de scrollear el contenido por dentro con la sidebar
   fija. Hay **dos palancas equivalentes** y la familia usa las dos: la utilidad
   en el markup (`lg:grid-rows-1`, que funciona porque daisyUI ya trae
   `grid-row-start: 1` en los dos hijos) o la regla en `app.css`
   (`grid-auto-rows: minmax(0, 1fr)` sobre `.drawer`, que es la general — vale
   también si la fila fuera de verdad implícita, con items auto-colocados).
   **Una de las dos, nunca ninguna.** `repeat(1, minmax(0, 1fr))` acota la fila al
   viewport: el `minmax(0, …)` es lo que permite bajar por debajo del contenido.
   **Scope `lg`**, no negociable: en `< lg` el `.drawer-side` es overlay
   `position: fixed` y no hay columna que acotar (móvil se comporta igual con y
   sin la clase).
2. **No lo tapes con `overflow: hidden` en `.drawer`.** La fila seguiría
   creciendo (recortar no acota el tamaño) y mataría el menú de usuario del rail,
   que abre hacia la derecha y necesita `overflow: visible` en `.drawer-side`
   (§C12.1).
3. **El que scrollea es `main`** (`flex-1 min-h-0 overflow-y-auto`), no el
   documento. La barra del contenido (`h-14 shrink-0`) y la sidebar quedan fijos.

Cómo se verifica (se mide, no se mira) — con el CSS **compilado** y contenido
largo, a 1440×900 y 1280×800, expandido y en rail:

- `documentElement.scrollHeight == innerHeight` (el documento no scrollea);
- `main.scrollHeight > main.clientHeight` (el scroll vive dentro de `main`);
- con la **ventana** scrolleada 400px, el `getBoundingClientRect().top` de la
  sidebar sigue en `0` y el de la barra del contenido también.

Medición del caso real (contenido 2968px, ventana 900px): **sin** la clase, fila
del drawer `3024px`, documento `3024`, `main` `2968/2968` (sin scroll interno) y
sidebar `top: -400` con la ventana scrolleada; **con** la clase, fila `900`,
documento `900`, `main` `844/2968` con scroll interno y sidebar `top: 0` / bottom
`900`. Igual en rail (sidebar 240 → 64px) y sin diferencias en móvil 500×800.

---

## Apéndice A — Tema `dim` (valores de referencia)

Fuente de verdad: los `oklch()` que el plugin emite en
`priv/static/assets/css/app.css`. Los hex son conversión aproximada (sin
gamut-mapping), sólo para leer la tabla. Contraste = WCAG del par con su
`*-content`.

| Token | oklch | ≈hex | Rol · contraste |
|---|---|---|---|
| `--color-base-100` | `oklch(30.857% 0.023 264.149)` | `#2a303c` | fondo de app  |
| `--color-base-200` | `oklch(28.036% 0.019 264.182)` | `#242933` | paneles / hover de fila  |
| `--color-base-300` | `oklch(26.346% 0.018 262.177)` | `#20252e` | chips, bordes  |
| `--color-base-content` | `oklch(82.901% 0.031 222.959)` | `#b2ccd6` | texto principal · texto 7.9:1 vs base-100 |
| `--color-primary` | `oklch(86.133% 0.141 139.549)` | `#9fe88d` | **acción principal** (botón por defecto) · 13.0:1 |
| `--color-secondary` | `oklch(73.375% 0.165 35.353)` | `#ff7d5d` | acento de marca · 7.9:1 |
| `--color-accent` | `oklch(74.229% 0.133 311.379)` | `#c792e9` | acento "extra" · 8.2:1 |
| `--color-neutral` | `oklch(24.731% 0.02 264.094)` | `#1c212b` | panels/chips oscuros · 9.6:1 |
| `--color-success` | `oklch(86.171% 0.142 166.534)` | `#62efbd` | ok, activo · 13.2:1 |
| `--color-warning` | `oklch(86.163% 0.142 94.818)` | `#efd057` | aviso · 12.5:1 |
| `--color-error` | `oklch(82.418% 0.099 33.756)` | `#ffae9b` | destructivo · 10.8:1 |
| `--color-info` | `oklch(86.078% 0.142 206.182)` | `#28ebff` | informativo · 13.0:1 |

Pares `*-content`: `primary-content` `oklch(17.226% 0.028 139.549)` ·
`secondary-content` `oklch(14.675% 0.033 35.353)` · `accent-content`
`oklch(14.845% 0.026 311.379)` · el resto de los semánticos también lleva su par.

Forma del tema: `color-scheme: dark` · radios `box 1rem` / `field 0.5rem` /
`selector 1rem` · `--border 1px` · `--depth 0` · `--noise 0`.

> **El primary pinta todos los botones por defecto.** `CoreComponents.button/1`
> sin `variant` emite `btn-primary btn-soft`, así que el color del primary es el
> esperado, no un bug de CSS. Para otro color usá la utilidad explícita
> (`btn-secondary`, `btn-accent`) — **no** redefinas el primary del tema.

## Apéndice B — Verificar una implementación

Adaptá los caminos a tu repo. Cada grep corresponde a una regla del doc:

```bash
grep -n 'data-theme' lib/<app>_web/components/layouts/root.html.heex    # el tema declarado (§C2)
grep -n 'themes:' assets/css/app.css                                    # un solo tema `--default` (§C2)
grep -rn '@apply' assets/css/                                           # 0
grep -rn 'table-zebra' lib/                                             # 0 (sin zebra, §C6)
grep -rn 'overflow-x-auto' lib/                                         # tablas/paneles anchos envueltos (§C3)
grep -c 'for="sidebar-collapse"' lib/<app>_web/components/layouts.ex    # 1 (toggle único, §C12.1)
grep -c 'class="drawer lg:drawer-open[^"]*lg:grid-rows-1' lib/<app>_web/components/layouts.ex  # 1 (fila del drawer acotada, §C12.5)
grep -c 'grid-auto-rows: minmax(0, 1fr)' assets/css/app.css             # 1 si la palanca es el CSS (§C12.5)
grep -c 'aside[^>]*label for="sidebar' lib/<app>_web/components/layouts.ex  # 0 (el sidebar no lleva toggle propio)
grep -rn 'p-4 sm:p-6\|p-4 pb-16 sm:p-6' lib/                            # padding mobile-first (§C3.1)
grep -rnE '#[0-9a-fA-F]{3,6}\b' lib/ assets/css/app.css                 # 0 fuera de marca (§C2.1) y paletas nombradas (§C9)
mix tailwind <app> && grep -c 'data-theme=dim' priv/static/assets/css/app.css  # 1 (§C2)
```

---

## Custom — TokenGate

Este `DESIGN.md` es de **TokenGate**, la consola de un gateway LLM. El Commons
de arriba es idéntico al de la familia; acá sólo va lo que **no** se puede
compartir, con el porqué.

### T1. Tema y CSS propio

TokenGate corre el tema de la familia tal cual: `themes: dim --default` en
`assets/css/app.css` y `data-theme="dim"` en `root.html.heex` (§C2, valores en
el **Apéndice A**). No hay excepción de tema que declarar.

Inventario del CSS propio (todo lo que hay, además de las reglas globales del
Commons):

| Bloque | Para qué |
|---|---|
| `@import "tailwindcss" source(none)` + `@source` ×3 | escaneo explícito de clases (v4 no autodescubre) |
| `@import "phoenix-colocated/…"` + `@source` de `_build/dev/phoenix-colocated` | CSS de hooks colocados en LiveView (dev) |
| `@plugin "../vendor/heroicons"` | `<.icon name="hero-…">` |
| `@plugin "../vendor/daisyui" { themes: dim --default }` | el tema |
| `@custom-variant phx-click-loading` / `phx-submit-loading` / `phx-change-loading` | estados de carga de LiveView |
| `[data-phx-session], [data-phx-teleported-src] { display: contents }` | que los wrappers de LiveView no rompan el layout |
| `@media (min-width: 64rem)` sobre `#sidebar-collapse:checked ~ .drawer …` | el **rail** de §C12.1: `.shell-hide` se esconde, los enlaces centran su icono, el `.drawer-side` pierde el recorte y el menú de usuario abre hacia la derecha. El CSS del rail lo pone cada app: el Commons lo describe, no lo entrega |
| `.table tbody tr:hover` + `transition` (§C6) | hover de fila unificado |
| `@keyframes reset-colon-blink` + `.reset-colon` + `prefers-reduced-motion` | el `:` que late en el contador del tope diario |

**Regla: ningún bloque propio declara color.** El único color del CSS custom es
el hover de tabla, y sale de `var(--color-base-200)`.

Ilustración de la regla (los tres casos que se apartan, cada uno con su razón):

- **Filtro del nav del sidebar.** El hook colocado `.NavFilter` esconde enlaces
  con `classList.toggle("hidden")`; no declara color.
- **Paleta categórica del proveedor.** `StatsHelpers.provider_color/1` usa 16
  `bg-*-500` de Tailwind crudo (`@provider_colors`). Es intencional: hacen falta
  16 colores distinguibles y el tema trae 11 tokens; no son "colores de UI" sino
  series. El color viaja por **índice en la leyenda**, no por slug.
- **Podio de rankings** (`rank_badge/1`, `medal/1`) tokenizado: 1º
  `bg-warning text-warning-content`, 2º `bg-base-300 text-base-content`, 3º
  `bg-secondary text-secondary-content`. Antes eran `amber-200` / `slate-200` /
  `orange-300`, elegidos para fondo oscuro: sobre un `base-100` claro daban
  1.0–1.4:1, es decir invisibles. Los tokens actuales funcionan en cualquier tema.

### T2. Dos shells

#### T2.1 Público — `Layouts.app/1`

Navbar `navbar px-4 sm:px-6 lg:px-8` con logo + "Iniciar sesión"; `<main
class="px-4 py-20 sm:px-6 lg:px-8">` con el contenido en `mx-auto max-w-2xl
space-y-4`. `hide_navbar` para login/registro (páginas self-contained y
centradas). Es el único sitio de la app sin el shell de §C12.

#### T2.2 Consola — `Layouts.dashboard/1`

Implementa §C12 tal cual: raíz `h-screen bg-base-100` + `drawer lg:drawer-open
h-full lg:grid-rows-1` (en TokenGate la fila del drawer se acota con la utilidad
del markup; §C12.5), barra de contenido `h-14` con el **único** toggle (gaveta en
móvil, rail en desktop), sidebar `w-60 bg-base-200/50`, nav con `<.nav_link>` /
`<.nav_group>` y pie con `<.user_footer>`. Lo que TokenGate resuelve distinto:

1. **Sin selector de contexto.** TokenGate es mono-tenant: no hay workspaces
   que cambiar. En el header del sidebar sólo van logo + wordmark.
2. **El buscador no es un form GET.** TokenGate no tiene buscador global, así
   que el campo filtra en el cliente los enlaces del sidebar (hook colocado
   `.NavFilter`; `⌘K` / `Ctrl+K` lo enfoca, `Escape` limpia). Cuando exista un
   buscador real, el campo pasa a ser el form GET de §C12.2.
3. **Menú de usuario** (`#user-menu`, `<.menu_item>`): **Profile** (dispara el
   `ProfileModal` con un click sintético sobre el avatar), **API keys** (→
   `/dashboard`, donde el usuario administra sus claves), *(divider)* **idioma**
   y **zona horaria** (los dos selectores de preferencias), *(divider)* **Log
   out**. No hay "Workspaces" porque no existen.
4. **La identidad ya no vive en una topbar.** El nombre y el email van en el pie
   del sidebar; el rol, en el `ProfileModal` (lo abre el avatar, que es su
   disparador). El botón de salir también vive en el menú.
5. **El rail persiste.** `#sidebar-collapse` se guarda en `localStorage` (hook
   colocado `.SidebarRail`): el checkbox se re-monta en cada navegación y sin
   persistir el rail se expandiría solo en cada clic.

**Navegación** (`<.nav_group>` agrupa; `<.nav_link>` por enlace, activo por
`active_path?/2` contra `current_path`, con badge opcional):

| Grupo | Links |
|---|---|
| *(sin grupo, tope)* | Dashboard · Supervised services *(no-admin con supervisados)* · Stats · Calculator *(admin)* |
| **Catalog** | Labs · Providers *(badge `badge-error` de alertas)* · Models |
| **Access** | Services · Users |
| **Budget** | Limit profiles · Top-ups · Global daily cap |
| **Operations** | Monitoring · Audit · Observability · Notifications · Maintenance |

Los `id` del nav los deriva `<.nav_link>` de su `path` (`/catalog/models` →
`sidebar-link-catalog-models`) salvo que se pase uno explícito: son las anclas
de `test/`.

### T3. Componentes extra

| Componente | Qué es |
|---|---|
| `<.model_picker>` | badges toggleables para grants de modelos. Firma: `id`, `models`, `granted_ids`, `toggle_event`, `target_value`, `locked_ids`, `extra_ids`, `denied_ids`, `empty_text`. Estados: granted `badge-primary` · extra `badge-accent` · locked `badge-primary opacity-60` (disabled) · denied `badge-error badge-outline line-through opacity-70` · libre `badge-outline hover:badge-primary/50`. Emite `phx-value-target-id` + `phx-value-model-id` |
| `<.input type="datalist">` | texto libre + sugerencias (`<datalist>`) para catálogos largos |
| `<.input ... hint=…>` | texto de ayuda bajo el campo |
| `<.button variant="primary" \| nil>` | `btn-primary` / `btn-primary btn-soft` |
| `<.table id rows row_id row_click row_item>` con `:col`/`:action` | tabla con soporte de `stream` (`table-sm`) |
| `<.keys_badge>` / `<.keys_panel>` | claves API de un sujeto (`user` \| `service`): conteo en la tabla y panel de alta/revocación (`KeysPanel`) |
| `<.admin_search>` · `<.sort_button>` · `<.admin_identity>` · `<.admin_pagination>` | header con búsqueda, columnas ordenables, celda de identidad y paginado de las páginas admin (`AdminComponents`) |
| `<.admin_delete_modal>` | confirmación destructiva: **compone `<.modal>`** y nombra el objetivo y lo que se pierde. Es a propósito más explícita que el `data-confirm` simple de §C7 |
| `<.ProfileModal>` | LiveComponent de la cuenta del usuario: datos + cambio de contraseña. Vive en el pie del sidebar |

**Badges semánticos por dominio** (`StatsHelpers`): tiers `tier_badge_class/1`
(S → `badge-success`, A → `badge-info`, B → `badge-warning`, C →
`badge-warning badge-outline`, D → `badge-error`, default `badge-ghost`).
Error HTTP: `error_class_badge/1` (4xx → `badge-warning`, 5xx → `badge-error`).

### T4. Pickers: implementación de referencia

Implementación real del patrón **Commons C8**:

- **Combobox single/multi:** `models_live.ex` — `phx-focus="open_scope_picker"`,
  `phx-change` + `phx-debounce="200"`, dropdown
  `absolute z-50 left-0 right-0 mt-1 … max-h-40/60 overflow-y-auto`, filas
  `hover:bg-primary/10` y activa `bg-primary/10 font-semibold` + `✓`; chips
  `badge badge-warning badge-sm gap-1 cursor-pointer` con `<.icon hero-x-mark>`.
  Handlers: `resolve_scope_search/1`, `close_scope_pickers`.
- **Autocomplete de email:** `group_members_live.ex` (`phx-change="search_email"`,
  `phx-debounce="300"`, sugerencias con email + nombre + rol).

### T5. Tabla canónica

`observability_live.ex`: `overflow-x-auto card bg-base-100 border border-base-300
shadow-sm` + `table table-sm` (37 usos de `table-sm` en `lib/`, **0** de
`table-zebra`). Para columnas de ancho fijo: `table table-sm table-fixed w-full`
(`models_live`, `notifications_live`).

### T6. Gráficas

Sin librería (Commons C9). Dos formas reales:

- **Bar chart SVG:** `dashboard_live.ex` — `card` + `card-body`, título
  `card-title text-base` + icono; `<svg viewBox="0 0 400 150" class="flex-1 h-40"
  preserveAspectRatio="none">` con `<rect rx="2">` + `<title>` (tooltip),
  baseline `<line class="stroke-base-300">` y grid `stroke-dasharray="2,2"`;
  eje Y en columna `text-[10px] text-base-content/50 w-8`, eje X `text-[10px]`.
- **Sparklines de barras:** `lib/tokengate_web/live/stats/{models,groups,services}.ex`
  y `supervised_service_stats_live.ex` con
  `style="height: #{Stats.sparkline_bar_height(count, max)}%"`; escalas y color
  en `stats_helpers.ex` (`sqrt` con mínimo 4%, `sparkline_color/1`,
  `provider_color/1`, `pivot_daily_series/1`).

### T7. Referencias (código real)

- `lib/tokengate_web/components/core_components.ex` — `flash`, `button`
  (`variant` primary/nil), `input` (select/datalist/textarea/checkbox/hint),
  `header`, `table` (stream + `table-sm`), `list`, `icon`, `model_picker`, **y
  las primitivas de §C4**: `nav_link`, `nav_group`, `menu_item`, `section`,
  `modal`, `empty_state` — `show`/`hide`, `translate_error(s)`.
- `lib/tokengate_web/components/layouts.ex` — `app/1` (shell público),
  `dashboard/1` (shell de §C12), `dashboard_sidebar`, `user_footer`,
  `locale_selector`, `timezone_selector`, `flash_group`.
- `lib/tokengate_web/components/admin_components.ex` — `admin_search`,
  `sort_button`, `admin_identity`, `admin_delete_modal`, `admin_pagination`.
- `lib/tokengate_web/components/keys_panel.ex` — `keys_badge`, `keys_panel`.
- `lib/tokengate_web/live/profile_modal.ex` — cuenta del usuario en un `<dialog>`
  nativo con hook colocado `.ProfileModal` (top layer: el `backdrop-blur` del
  shell no le afecta). Es la única superficie que sigue usando `<dialog>`.
- `lib/tokengate_web/live/models_live.ex` — combobox single/multi,
  `resolve_scope_search/1`, `close_scope_pickers`.
- `lib/tokengate_web/live/group_members_live.ex` — modal overlay, autocomplete de
  email, tabla, empty state.
- `lib/tokengate_web/live/observability_live.ex` — tabla canónica card + `table-sm`.
- `lib/tokengate_web/stats_helpers.ex` — formatters, badges semánticos, paleta de
  proveedores y escalas de charts.
- `assets/css/app.css` — tema `dim --default`, regla global de tablas
  (`var(--color-base-200)`: en daisyUI 5 los alias `--b1/--b2/--b3` ya no
  existen), CSS del rail y el latido `.reset-colon`. Inventario en §T1.
- Skills: `liveview-ui-wiring` (pickers), `liveview-nav-active-state` (estado
  activo del sidebar), `phoenix-daisyui-theming` (tema).
