# DESIGN.md — sistema de UI

Estándar de interfaz de la familia de apps que comparten un **mismo lenguaje
visual**. El documento tiene dos partes:

- **Commons** — la base compartida por todas las apps: tema y tokens, elementos
  básicos, composición, estados y convenciones. Es idéntica en todos los repos:
  si cambias algo aquí, cámbialo en los tres `DESIGN.md`.
- **Custom** — lo específico de **esta** app (TokenGate), que además es la
  referencia del Commons: ante la duda de cómo se ve un control, mira un LiveView
  de TokenGate antes de inventar.

> **Regla de oro de este doc: refleja el código.** Todo lo que se afirma aquí debe
> poder señalarse en `lib/tokengate_web/…` o `assets/css/app.css`. Si el código
> cambia, este archivo cambia con él.

---

## Commons — base compartida de la familia

### C1. Principios

1. **daisyUI nativo + Tailwind.** No inventes componentes si daisyUI ya trae
   (`btn`, `card`, `table`, `badge`, `input`, `select`, `alert`, `modal`,
   `dropdown`, `tabs`). CSS propio sólo para convenciones **globales**.
2. **Un solo tema por app, elegido en `app.css`.** La convención familiar es
   daisyUI `dark --default`; **TokenGate corre `dim --default`** (excepción
   consciente, §Custom). Dran y Gorim siguen en `dark`. Nada de hex/oklch
   hardcodeado en plantillas: siempre las vars del tema.
3. **Reusar antes de crear.** Mira `*Web.CoreComponents` antes de escribir markup
   a mano: inputs, tablas, headers, iconos ya están.
4. **Verificable.** Todo control interactivo lleva `id` estable para tests
   (`has_element?/2`).

### C2. Tema y tokens

```css
/* assets/css/app.css */
@plugin "../vendor/heroicons";
@plugin "../vendor/daisyui" {
  themes: dark --default;   /* ← tema ÚNICO de la familia (TokenGate: dim, §Custom) */
}
```

```heex
<%!-- lib/<app>_web/components/layouts/root.html.heex — TokenGate: data-theme="dim" --%>
<html data-theme="dark">
```

**Regla del scaffold:** si `app.css` venía con `themes: false` + bloques
`@plugin "../vendor/daisyui-theme"`, hay que **borrar** esos bloques (y el JS del
switcher de tema en `root.html.heex`) al fijar el tema built-in, o el tema viejo
queda pegado.

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

### C3. Layout base

- El contenido principal va en un `<main>`; el **shell** (navbar/sidebar/topbar)
  es de cada app → ver **Custom**.
- **Header de página:** `<.header>` — título (`:inner_block`) + `:subtitle` +
  `:actions`.
- **Filtros y acciones, alineados a la DERECHA** (slot `:actions` o
  `justify-end`). Nunca a la izquierda.
- **Contenedores anchos** (tablas/paneles) envueltos en `overflow-x-auto`.

### C4. Elementos básicos

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

- `flash` · `button` · `input` (tipos: `text/select/datalist/textarea/checkbox/…`,
  con `hint` y `placeholder`) · `header` · `table` · `list` · `icon` ·
  `model_picker` · `show`/`hide` · `translate_error`/`translate_errors`.

### C5. Tarjetas (cards)

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
- **Card de sección con header** (badge de icono + título + caption): cada app la
  tiene → ver **Custom**.
- **Card de modal:** `shadow-xl` en vez de `shadow-sm` (ver C7).
- Sombras y radios del tema (`--radius-box`, `shadow-sm/md/xl`); no a mano.

### C6. Tablas

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

### C7. Modales

Patrón estándar = overlay `div`, **no `<dialog>`**. Cerrar = volver el assign.

#### C7.1 Modal simple (una columna)

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

#### C7.2 Modal de dos columnas (contenido + sidebar de metadata)

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
        <span class="text-[11px] font-semibold px-2 py-0.5 rounded-full shrink-0 bg-primary/10 text-primary">Nota</span>
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

### C8. Buscadores y selects

Elige el control por la matriz: ¿cuántos valores? × ¿la lista es grande (necesita buscar)?

| | **1 valor** | **N valores** |
|---|---|---|
| **Pocos** (≤ ~10, sin scroll) | **C8.1 select** | **C8.5 badges toggleables** |
| **Muchos** (buscar) | **C8.3 combobox single** | **C8.4 combobox multi** |

Para texto libre con sugerencias (catálogo largo, valor custom): **C8.2 datalist**.

#### C8.1 Select simple (1 valor, sin buscar)

`<.input type="select" options={…} prompt="…" />` — el `<select>` nativo
(`w-full select`). Para un select suelto fuera de un form:
`<select class="select select-bordered select-sm w-full">`.

```heex
<.input field={@form[:owner_id]} type="select" prompt="Elige…" options={@owner_options} />
```

#### C8.2 Datalist (texto libre + sugerencias)

`<.input type="datalist" options={…} />` — input de texto con `<datalist>`: el
usuario elige de la lista **o** escribe cualquier valor.

```heex
<.input field={@form[:model]} type="datalist" label="Modelo" options={@catalog} />
```

#### C8.3 Combobox single (1 valor, con buscar)

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

#### C8.4 Combobox multi (N valores, con buscar)

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

#### C8.5 Badges toggleables (N valores, sin buscar)

Para listas cortas (grants): botones `badge` que alternan. Estado: seleccionado =
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

#### Reglas duras de los combobox (vienen de bugs reales)

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

### C9. Gráficas (charts)

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
- **Color de serie:** de una paleta definida en la app (nunca hex suelto).
- **Ejes y labels:** `text-[10px]`/`text-xs`, `text-base-content/40-50`,
  `tabular-nums` en los valores.
- **Tooltip:** `<title>` dentro del nodo SVG (o `title=` en la barra).
- **Empty state:** contenedor de la misma altura con texto centrado
  (`text-base-content/40`).
- **Sparkline:** `<svg viewBox="0 0 200 30">` + `<polyline points=… fill="none"
  stroke="currentColor" class="text-primary/40" stroke-width="1.5">`.
- **Hover:** realce sutil (`group-hover:brightness-110`), sin re-render.

### C10. Estados

| Estado | Estándar |
|---|---|
| Loading | `.skeleton` (shimmer) o `loading loading-spinner` |
| Empty | icono + texto centrado (`text-base-content/40`) |
| Error | `text-error` inline, o `alert alert-error` |
| Éxito | flash `alert-info` (toast top-end) |

### C11. Convenciones

- **`id` estable** en todo control clave (forms, botones, filas) → `has_element?/2`.
  Form: `id="thing-form"`; fila: `id={id}` (del stream).
- **Assigns por picker:** `<kind>_search` / `<kind>_open` / `current_<kind>_id(s)`.
- **Filtros** alineados a la **derecha** del header, siempre.
- **Modales** = overlay div; cierre por assign.
- **Datos crudos nunca en pantalla:** formatters.
- **Tema:** sólo vars del tema; cero hex/oklch hardcodeado.
- **i18n:** `Gettext`.
- Cierra siempre con **`mix precommit`** (alias en `mix.exs`).

---

## Custom — TokenGate

Este `DESIGN.md` es de **TokenGate**. Tema **`dim` (único)**:

```heex
<%!-- lib/tokengate_web/components/layouts/root.html.heex --%>
<html lang={TokengateWeb.Gettext.current_locale()} data-theme="dim">
```

```css
/* assets/css/app.css */
@plugin "../vendor/daisyui" { themes: dim --default; }
```

> Excepción consciente a la convención familiar (`dark`): TokenGate corre `dim`.
> Historial: `night --default, light` → `dark` → `fantasy` → `garden` → `dim`
> (decisión actual: es `light` atenuado — daisyUI lo genera de la paleta de
> `light`, theme genérico y luminoso).

### Paleta real de `dim`

Fuente de verdad: los `oklch()` que el plugin emite en
`priv/static/assets/css/app.css`. Los hex son conversión aproximada (sin
gamut-mapping), sólo para leer la tabla. Contraste = WCAG del par con su
`*-content`.

| Token | oklch | ≈hex | Rol · contraste |
|---|---|---|---|
| `--color-base-100` | `oklch(30.857% 0.023 264.149)` | `#2a303c` | fondo de app · texto 7.9:1 ✅ |
| `--color-base-200` | `oklch(28.036% 0.019 264.182)` | `#242933` | paneles / hover de fila · 8.7:1 ✅ |
| `--color-base-300` | `oklch(26.346% 0.018 262.177)` | `#20252e` | chips, bordes · 9.2:1 ✅ |
| `--color-base-content` | `oklch(82.901% 0.031 222.959)` | `#b2ccd6` | texto principal |
| `--color-primary` | `oklch(86.133% 0.141 139.549)` | `#9fe88d` | verde lima (el botón por defecto) · 13.0:1 ✅ |
| `--color-secondary` | `oklch(73.375% 0.165 35.353)` | `#ff7d5d` | coral · 7.9:1 ✅ |
| `--color-accent` | `oklch(74.229% 0.133 311.379)` | `#c792e9` | lila · 8.2:1 ✅ |
| `--color-neutral` | `oklch(24.731% 0.02 264.094)` | `#1c212b` | panels/chips oscuros · 9.6:1 ✅ |
| `--color-success` | `oklch(86.171% 0.142 166.534)` | `#62efbd` | ok, en vivo · 13.2:1 ✅ |
| `--color-warning` | `oklch(86.163% 0.142 94.818)` | `#efd057` | aviso, oro del podio · 12.5:1 ✅ |
| `--color-error` | `oklch(82.418% 0.099 33.756)` | `#ffae9b` | destructivo · 10.9:1 ✅ |
| `--color-info` | `oklch(86.078% 0.142 206.182)` | `#28ebff` | informativo · 13.0:1 ✅ |

Pares `*-content` (texto sobre cada token): `primary-content`
`oklch(17.226% 0.028 139.549)` · `secondary-content`
`oklch(14.675% 0.033 35.353)` · `accent-content` `oklch(14.845% 0.026 311.379)` ·
`neutral-content` = `base-content` · y el resto en la misma banda (~17%).

Forma del tema: `color-scheme: dark` · radios `box 1rem` / `field 0.5rem` /
`selector 1rem` · `--border 1px` · `--depth 0` · `--noise 0`.

> **El primary pinta todos los botones por defecto.** `CoreComponents.button/1`
> sin `variant` emite `btn-primary btn-soft`, así que el verde `#9fe88d` es el
> color esperado, no un bug de CSS. Para otro color usá la utilidad explícita
> (`btn-secondary` coral, `btn-accent` lila) — **no** redefinas el primary del
> tema. En `dim` TODOS los pares `color/content` pasan AA (≥7.9:1).

### T1. `app.css` (67 líneas)

Sólo tema + heroicons + `@custom-variant` de LiveView + `[data-phx-session]` y
**la regla global de tablas** (que es exactamente la de §C6):

```css
.table tbody tr { transition: background-color 150ms ease; }
.table tbody tr:hover { background-color: color-mix(in oklab, var(--color-base-200) 60%, transparent); }
```

**No hay utilidades tipográficas propias**: usa Tailwind + daisyUI directo
(`text-lg font-semibold leading-8` para títulos, `text-sm text-base-content/70`
para subtítulos, `text-xs text-base-content/50` para metadata, eyebrow
`text-xs font-semibold uppercase tracking-wide text-base-content/40`).

#### ¿Qué hay de CSS propio? (inventario)

| Bloque | Para qué |
|---|---|
| `@import "tailwindcss" source(none)` + `@source` ×3 | escaneo explícito de clases (v4 no autodescubre) |
| `@import "phoenix-colocated/…"` + `@source` de `_build/dev/phoenix-colocated` | CSS de hooks colocados en LiveView (dev) |
| `@plugin "../vendor/heroicons"` | `<.icon name="hero-…">` |
| `@plugin "../vendor/daisyui" { themes: dim --default }` | el tema |
| `@custom-variant phx-click-loading` / `phx-submit-loading` / `phx-change-loading` | estados de carga de LiveView |
| `[data-phx-session], [data-phx-teleported-src] { display: contents }` | que los wrappers de LiveView no rompan el layout |
| `.table tbody tr:hover`, `transition` (§C6) | hover de fila unificado |
| `@keyframes reset-colon-blink` + `.reset-colon` + `prefers-reduced-motion` | el `:` que late en el contador del tope diario |

**Regla: ningún bloque propio declara color.** El único color del CSS custom es
el hover de tabla, y sale de `var(--color-base-200)`. Si hace falta un color, se
usa el token/utility del tema — nunca hex, oklch ni la paleta cruda de Tailwind.

**Excepciones documentadas** (las dos únicas):

- **Paleta categórica del proveedor.** `StatsHelpers.provider_legend_color/2`
  usa 16 `bg-*-500` de Tailwind crudo (`@provider_colors`). Es intencional:
  hacen falta 16 colores distinguibles y el tema trae 11 tokens; no son "colores
  de UI" sino series.
- **Podio de rankings** (`rank_badge/1`, `medal/1`) tokenizado: 1º
  `bg-warning text-warning-content` (12.5:1 en dim), 2º `bg-base-300
  text-base-content` (9.2:1), 3º `bg-secondary text-secondary-content`
  (7.9:1). Antes eran `amber-200` / `slate-200` / `orange-300`, elegidos para
  fondo oscuro: sobre el `base-100` de garden (claro) daban **1.0–1.4:1**, es
  decir invisibles. Los tokens actuales funcionan en cualquier tema.

### T2. Dos shells

#### T2.1 Público — `Layouts.app/1`

Navbar `navbar px-4 sm:px-6 lg:px-8` con logo + "Iniciar sesión"; `<main
class="px-4 py-20 sm:px-6 lg:px-8">` con contenido en `mx-auto max-w-2xl
space-y-4`. `hide_navbar` para login/registro (páginas self-contained y
centradas). Cierra con `<.flash_group>`.

#### T2.2 Consola — `Layouts.dashboard/1`

El shell de la ops console (LiveViews autenticadas del `live_session :admin`):

- `drawer lg:drawer-open min-h-screen bg-base-200` con sidebar
  `w-64 bg-base-100 border-r border-base-300` (logo + `nav` + pie).
- **Topbar sticky** `h-16 bg-base-100/80 backdrop-blur border-b border-base-300`:
  botón de menú (móvil), email + rol, avatar (`bg-primary`), botón Salir
  (`data-confirm`).
- **Banner de impersonación** (`id="impersonation-banner"`,
  `bg-warning text-warning-content`, con botón `#stop-impersonating`).
- `<main class="flex-1 p-4 sm:p-6 lg:p-8">`.
- Pie del sidebar: `<.locale_selector>` + `<.timezone_selector>`
  (`id="timezone-selector"`, `select … select-sm`, form `phx-change="set-timezone"`).

**Navegación** (`sidebar_section` agrupa; `sidebar_link` por link, activo por
`current_path`, con `badge badge-error` opcional para alertas):

| Grupo (`sidebar_section`) | Links |
|---|---|
| *(sin grupo, tope)* | Dashboard · Supervised services *(no-admin con supervisados)* · Stats · Calculator *(admin)* |
| **Catalog** | Labs · Providers *(badge de alertas)* · Models |
| **Access** | Services · Users |
| **Budget** | Limit profiles · Top-ups · Global daily cap |
| **Operations** | Monitoring · Audit · Observability · Notifications · Maintenance |

### T3. Componentes extra

| Componente | Qué es |
|---|---|
| `<.model_picker>` | badges toggleables para grants de modelos. Firma: `id`, `models`, `granted_ids`, `toggle_event`, `target_value`, `locked_ids`, `extra_ids`, `denied_ids`, `empty_text`. Estados: granted `badge-primary` · extra `badge-accent` · locked `badge-primary opacity-60` (disabled) · denied `badge-error badge-outline line-through opacity-70` · libre `badge-outline hover:badge-primary/50`. Emite `phx-value-target-id` + `phx-value-model-id`. |
| `<.input type="datalist">` | texto libre + sugerencias (`<datalist>`) para catálogos largos |
| `<.input ... hint=…>` | texto de ayuda bajo el campo |
| `<.button variant="primary" \| nil>` | `btn-primary` / `btn-primary btn-soft` |
| `<.table id rows row_id row_click row_item>` con `:col`/`:action` | tabla con soporte de `stream` (`table-sm`) |

**Badges semánticos por dominio** (`StatsHelpers`): tiers
`tier_badge_class/1` (S → `badge-success`, A → `badge-info`, B → `badge-warning`,
C → `badge-warning badge-outline`, D → `badge-error`, default `badge-ghost`).
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
  `phx-debounce="300"`, filas de sugerencia con email + nombre + rol).

### T5. Tabla canónica

`observability_live.ex`: `overflow-x-auto card bg-base-100 border border-base-300 shadow-sm`
+ `table table-sm` (36 usos de `table-sm` en `lib/`, **0** de `table-zebra`).
Para columnas de ancho fijo: `table table-sm table-fixed w-full` (`models_live`).

### T6. Gráficas (implementación TokenGate)

Sin librería (ver **Commons C9**). Dos formas reales:

- **Bar chart SVG:** `dashboard_live.ex` — `card` + `card-body`, título
  `card-title text-base` + icono; `<svg viewBox="0 0 400 150" class="flex-1 h-40"
  preserveAspectRatio="none">` con `<rect rx="2">` + `<title>` (tooltip),
  baseline `<line class="stroke-base-300">` y grid `stroke-dasharray="2,2"`;
  eje Y en columna `text-[10px] text-base-content/50 w-8`, eje X `text-[10px]`.
- **Sparklines de barras:** `lib/tokengate_web/live/stats/{models,groups,services}.ex`
  y `supervised_service_stats_live.ex` con
  `style="height: #{Stats.sparkline_bar_height(count, max)}%"`; escalas y color
  en `stats_helpers.ex` (`sqrt` con mínimo 4%, `sparkline_color/1`,
  `provider_legend_color/2`, `pivot_daily_series/1`).

### T7. Referencias (código real)

- `lib/tokengate_web/components/core_components.ex` — `flash`, `button`
  (`variant` primary/nil), `input` (select/datalist/textarea/checkbox/hint),
  `header`, `table` (stream + `table-sm`), `list`, `icon`, `model_picker`,
  `show`/`hide`, `translate_error(s)`.
- `lib/tokengate_web/components/layouts.ex` — `app/1` (público), `dashboard/1`
  (consola), `dashboard_topbar`, `dashboard_sidebar`, `sidebar_section`,
  `sidebar_link`, `locale_selector`, `timezone_selector`, `flash_group`.
- `lib/tokengate_web/live/models_live.ex` — combobox single/multi,
  `resolve_scope_search/1`, `close_scope_pickers`.
- `lib/tokengate_web/live/group_members_live.ex` — modal overlay, autocomplete de
  email, tabla, empty state.
- `lib/tokengate_web/live/observability_live.ex` — tabla canónica card + `table-sm`.
- `lib/tokengate_web/stats_helpers.ex` — formatters, badges semánticos, paleta de
  proveedores y escalas de charts.
- `assets/css/app.css` — tema `dim --default`, regla global de tablas
  (`var(--color-base-200)`: en daisyUI 5 los alias `--b1/--b2/--b3` ya no existen)
  y el latido `.reset-colon`. Inventario de CSS propio en §T1.
- Skills: `liveview-ui-wiring` (pickers), `phoenix-daisyui-theming` (tema).
