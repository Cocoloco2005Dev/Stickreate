# Stickreate — brief maestro para DeepSeek 4.1

> Contexto de producto y plan de trabajo para completar Stickreate. Repo: `C:\Users\cocol\source\Stickreate`. Rama principal `main`, release de referencia `v0.8.0`.

## Instrucción principal

Actúa como ingeniero senior de iOS y diseñador de producto. Termina la app con calidad de producto real, no de demo. Inspecciona el código antes de tocarlo: este documento describe intención y bugs reportados, pero no asumas que la implementación coincide ni que algo está resuelto solo porque exista una pantalla con ese nombre.

No uses subagentes. No reescribas el proyecto entero ni hagas refactors especulativos. Trabaja en fases pequeñas, con ownership claro de archivos, valida cada fase y conserva lo que ya funciona. Si una decisión depende de un límite de Apple, Vision o WhatsApp, consultá la documentación primaria enlazada abajo antes de codificarla. No inventes APIs.

El usuario está en Windows y no puede compilar con Xcode localmente. La compilación verificable es GitHub Actions en macOS. Después de cada fase que toque Swift, corré el workflow y arreglá todos los errores antes de declarar la fase terminada. No afirmes que algo funciona en iPhone si solo pasó el build de CI.

La UI va en inglés por ahora. Hablale al usuario en español, en frases cortas y sin mensajes largos llenos de listas (su cliente de chat corta el texto con listas). El nombre es Stickreate. Usá Liquid Glass de iOS 26 según el HIG; no simules glass con gradientes en todas las vistas.

El objetivo es que sea la mejor app de creación de stickers para WhatsApp, no la más cargada. Benchmark real, flujo corto, cero fricción, sin ads, sin cuentas, sin nube. "Mejor" significa confiable, rápido, claro y con control total del usuario, no la mayor cantidad de botones.

## Producto

Stickreate crea, ordena, edita y comparte stickers estáticos y animados de WhatsApp desde un iPhone. Podés tener packs mixtos dentro de la app; al exportar se dividen en un pack estático y uno animado porque WhatsApp no admite mezcla.

Principio rector: control explícito. Nunca quitar el fondo automáticamente. No presentar Vision como una IA externa o mágica: la herramienta se llama `Intelligent Cut` (o `Smart Select`) y usa Apple Vision en el dispositivo. El estado inicial conserva el fondo original.

Mantené todo privado y on-device. Nada de cuentas, nube, publicidad, generación remota ni analítica sin autorización.

## Estado conocido del repositorio

- SwiftUI, iOS 26 mínimo, Xcode 26, XcodeGen vía `project.yml`. El `.xcodeproj` se genera, nunca se commitea.
- WebP: `SDWebImage` y `SDWebImageWebPCoder` por SPM. Verificá las claves de opciones WebP contra el header de la versión resuelta antes de usarlas.
- Packs y fuentes se persisten en Documents (Codable + archivos locales).
- Vision: `VNGenerateForegroundInstanceMaskRequest`; composición con Core Image.
- Video: AVFoundation decodifica y muestrea frames; se codifica WebP animado.
- Export WhatsApp: JSON en `UIPasteboard` con tipo `net.whatsapp.third-party.sticker-pack` y apertura de `whatsapp://stickerPack`, con una espera de 0.7 s para mitigar el error 1000.
- CI: `.github/workflows/ios.yml`; en releases la versión se toma del tag.
- Icono original: `C:\Users\cocol\OneDrive\Escritorio\an-update-on-urusei-yatsuras-cast.jpg`. Ya hay un icono recortado; revisá el encuadre y que el asset catalog lo use bien.
- No borres ni recrees el historial de releases.

### Archivos a inspeccionar primero

- `project.yml`
- `Stickreate/RootView.swift`
- `Stickreate/Models/`: `StickerPack.swift`, `StickerItem.swift`, `StickerSource.swift`, `PackStore.swift`, `Limits.swift`, `Frame.swift`, `VideoDraft.swift`
- `Stickreate/Services/`: `StickerFactory.swift`, `StickerEncoder.swift`, `StickerSourceStore.swift`, `MaskEditor.swift`, `FrameExtractor.swift`, `BackgroundRemover.swift`, `WhatsAppExporter.swift`, `PackArchive.swift`
- `Stickreate/Features/Library/`: `LibraryView.swift`, `PackCard.swift`
- `Stickreate/Features/Editor/`: `AddStickerSheet.swift`, `PackEditorView.swift`, `StickerCell.swift`, `StickerEditorView.swift`, `VideoTrimView.swift`, `BackgroundChoiceView.swift`, `EmojiPickerSheet.swift`, `CameraPicker.swift`
- `Stickreate/Features/Settings/SettingsView.swift`
- `.github/workflows/ios.yml`

Antes de editar, corré `git status` y conservá cualquier cambio existente. No resetees ni sobrescribas archivos sin inspeccionarlos.

## Bugs reportados por el usuario — reproducir y verificar

No los cierres solo por existir una pantalla o función con ese nombre.

1. Crear un sticker de video se puede quedar en 100% durante la codificación, o tardar demasiado. El progreso actual puede medir extracción/Vision, pero la compresión WebP también tarda. 100% significa producto listo, nunca que terminó una fase intermedia.
2. Crash reportado al tocar Create tras recortar un video. Hay mitigaciones (decodificación acotada, downscale de frames, Vision off por defecto en video, `autoreleasepool`), pero hay que confirmar en device si persiste.
3. El recorte de imagen tenía coordenadas mal. La selección debe mapear el gesto a píxeles reales teniendo en cuenta letterboxing, escala, zoom, pan y orientación EXIF. La salida debe ser de verdad el rectángulo recortado.
4. El usuario no podía editar imágenes/video una vez dentro del pack. Edit debe abrir la fuente guardada, aplicar cambios y reemplazar el sticker en la misma posición, sin duplicar ni perder emojis/orden.
5. La edición se ve pobre y la UI en general está vacía. Hay cuatro capturas de referencia del usuario:
   - `C:\Users\cocol\.opencode\images\ses_f055bc198ffeNmXRh4puGjEICc\20261002_062139000_iOS-71380237.PNG`
   - `C:\Users\cocol\.opencode\images\ses_f055bc198ffeNmXRh4puGjEICc\20261002_062136000_iOS-af552363.PNG`
   - `C:\Users\cocol\.opencode\images\ses_f055bc198ffeNmXRh4puGjEICc\20261002_062151000_iOS-b4e71d21.PNG`
   - `C:\Users\cocol\.opencode\images\ses_f055bc198ffeNmXRh4puGjEICc\20261002_062324000_iOS-468dbd39.PNG`
6. En selección múltiple hay que poder editar cada medio por separado, quitar elementos de la cola, añadir más medios, cancelar una edición y reintentar un fallo sin perder el resto.
7. Error `com.third-party-stickers error 1000` al importar, aunque a veces el pack entra después. Mantené el delay tras escribir el pasteboard, una sola llamada a open, validación completa del payload y logging local sin datos privados.
8. Las Settings actuales son decorativas. Deben controlar funciones reales y persistidas, sin prometer nada que no cambie el comportamiento.
9. El usuario quiere pack mixto dentro de la app. WhatsApp exige separar tipos al exportar; mostrá que se generan dos packs, cada uno con su propia acción.
10. LiveContainer: `canOpenURL("whatsapp://")` puede dar false aunque `open("whatsapp://stickerPack")` sí pase al sistema. No deshabilites el export solo por esa comprobación.
11. El botón de agregar el pack a WhatsApp pasa desapercibido. La acción de exportar tiene que ser clara y prominente.
12. Los cambios hechos a una imagen no se guardaban antes de ponerla en el pack. Apply debe persistir la edición y su fuente antes de agregar.
13. El usuario quiere poder **marcar lo que debe quedar** en la imagen, no solo borrar partes.
14. El usuario quiere **recortar la imagen como tal** (reencuadrar), además de quitar/poner fondo.

## Diseño objetivo según las capturas del usuario

### Trim de video

Barra superior con atrás, título centrado `Trim` y acción `Next` en azul. Zona amplia, negra y letterboxed con el video. Abajo, una tira continua de miniaturas reales del video. El intervalo seleccionado es una ventana blanca redondeada con dos manejadores verticales gruesos; lo que está fuera del rango sigue visible pero oscurecido. No llenes la vista de timecodes ni controles que compitan. El fps va secundario y compacto.

### Elección de fondo

Explícita, con `Original` seleccionado al inicio. La referencia usa dos tarjetas grandes: `Original` e `Intelligent Cut`. La segunda puede mostrar la transparencia sobre checkerboard. Si corre Vision, mostrá progreso real. No la llames "AI" como si fuera un servicio remoto; el copy puede decir segmentación local con Apple Vision.

### Ajuste de imagen

Checkerboard visible, imagen con zoom/pan, herramientas claras y estados seleccionados evidentes. La referencia incluye `Intelligent Cut`, `Rectangle`, `Lasso`, `Full`, `Brush`, `Erase`, Undo, Redo, Cancel y Apply. Reglas: `Full` conserva todo; `Brush` restaura; `Erase` borra; Rectangle y Lasso deben poder **marcar qué queda y qué se quita** según la intención (ofrecé keep/remove o un modo claro). El usuario debe poder seleccionar y deseleccionar instancias del sujeto. La máscara se ve en vivo. Agregá una herramienta `Crop` para reencuadrar la imagen de verdad. Apply guarda el resultado.

### Densidad de UI

La app se siente vacía. Cada pantalla debe tener contenido útil y estados reales: onboarding breve la primera vez, estados vacíos con guía, miniaturas y previews, contadores, feedback de progreso por etapas, y errores accionables. No rellenes con adornos; llená con información y controles que el usuario necesita.

### Liquid Glass

Liquid Glass va en navegación y controles, no en el contenido. No aplicar glass a miniaturas, celdas, canvas ni tarjetas de pack. No glass sobre glass. No agregar fondos custom a toolbars/sheets que impidan el material del sistema. Probá Reduce Transparency, Increase Contrast, Reduce Motion, Dynamic Type y light/dark.

## Requisitos funcionales

### Crear desde medios

El picker acepta varias fotos, videos y GIFs. Cada selección va a una cola con miniatura, tipo, estado, editar, quitar y reintentar. Se pueden agregar más medios sin perder lo editado. Cada elemento se procesa por separado; un error en uno no borra el resto ni los cambios ya guardados.

Foto: elegir conservar fondo o usar Intelligent Cut; abrir Adjust; permitir selección inteligente de instancias, Rectangle, Lasso, Brush, Erase, Full, Crop, zoom/pan, undo/redo. Máscara en vivo. Apply guarda imagen final, fuente y metadatos en el pack.

Video: preview AVPlayer; filmstrip de thumbnails; dos manejadores; fps seleccionable; máximo 10 s. Después Original o Intelligent Cut, por defecto Original. Crear el sticker debe informar etapas reales: carga, extracción, Intelligent Cut si se pidió, compresión, listo/error. El porcentaje nunca llega a 100 antes de guardar stickerData, preview y metadatos.

GIF: conservar delays cuando sea posible, permitir editar/recortar si es viable, y respetar tamaño y duración. No convertir a fps fijo sin justificarlo.

### Editar dentro de un pack

Abrir un sticker guardado debe permitir editarlo. Guardar reemplaza el mismo sticker sin cambiar posición, emojis, cover ni fuente. Cancelar deja la versión previa intacta. Si falta la fuente (versión vieja o pack importado), explicar y permitir reemplazarla.

### Pack editor

Nombre/folder, reordenar por drag, elegir portada, duplicar, borrar con confirmación razonable, editar emojis (0–3), editar el sticker, ver estado/capacidad y exportar. La regla de que la primera posición es el tray debe quedar visible, para que reordenar no sorprenda.

### Exportar / importar / compartir

Un pack mixto ofrece dos acciones claras (estático y animado), indicando cuántos van en cada uno y avisando si alguno tiene menos de tres. La acción `Add to WhatsApp` debe ser prominente. `.stickreatepack` debe validar versión, tamaños, JSON, Base64 y no permitir rutas arbitrarias dentro del archivo.

### Compartir desde otras apps

El usuario quiere compartir una foto, GIF o video desde Fotos/otra app hacia Stickreate y **elegir a qué pack agregarla**. Revisá la documentación Apple de Share Extension y la arquitectura correcta; no llames "share extension" a un simple `onOpenURL`. Si hace falta target/entitlements/App Group, implementalo completo y validalo en CI. Como MVP, documentá si `ShareLink`/Open In alcanza para recibir los formatos y llevar al flujo con selector de pack. No afirmes que recibe desde otra app hasta probarlo en device.

## Requisitos WhatsApp (innegociables)

Fuente de verdad: FAQ y repo oficial.

- Cada sticker exactamente 512×512 px.
- Estático ≤100 KB; animado ≤500 KB. Apuntá a ≤450 KB de margen.
- Pack de 3 a 30 stickers.
- WhatsApp no acepta estáticos y animados mezclados. La app sí, pero en export son dos packs.
- Animación ≤10 s; cada frame ≥8 ms; el primer frame debe representar bien el loop.
- Tray estático 96×96 PNG ≤50 KB.
- Emojis opcionales, máximo 3 por sticker.
- Sin borde/stroke blanco automático (pedido explícito del usuario).
- Import iOS: JSON como `Data` en `UIPasteboard` bajo `net.whatsapp.third-party.sticker-pack`, luego `whatsapp://stickerPack`. Un pack por handoff; el usuario confirma en WhatsApp.
- El error 1000 no tiene tabla pública; el workaround reportado es esperar cerca de 1 s entre pasteboard y open. Nuestra app usa 0.7 s; probá 0.5–1.0 s en device y dejá una sola llamada a open.

Fuentes:
- https://faq.whatsapp.com/1056840314992666
- https://github.com/WhatsApp/stickers/tree/main/iOS
- https://github.com/WhatsApp/stickers/blob/main/iOS/WAStickersThirdParty/Limits.swift
- https://github.com/WhatsApp/stickers/blob/main/iOS/WAStickersThirdParty/Interoperability.swift
- https://github.com/WhatsApp/stickers/blob/main/iOS/WAStickersThirdParty/StickerPack.swift

## Requisitos Apple y fuentes primarias

Usá componentes del sistema cuando resuelvan bien el problema. Respetá permisos y explicalos. La cámara requiere `NSCameraUsageDescription`. PhotosPicker debe funcionar con acceso limitado sin pedir la fototeca completa si no hace falta. Para importar packs, usá archivos locales con manejo correcto de security-scoped URLs.

- HIG Materials: https://developer.apple.com/design/human-interface-guidelines/materials
- Adopting Liquid Glass: https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass
- SwiftUI Liquid Glass sample: https://developer.apple.com/documentation/swiftui/landmarks-building-an-app-with-liquid-glass
- WWDC25 Meet Liquid Glass: https://developer.apple.com/videos/play/wwdc2025/219/
- WWDC25 Build a SwiftUI app with the new design: https://developer.apple.com/videos/play/wwdc2025/323/
- PhotosPicker: https://developer.apple.com/documentation/photosui/photospicker
- AVAssetImageGenerator: https://developer.apple.com/documentation/avfoundation/avassetimagegenerator
- AVPlayer: https://developer.apple.com/documentation/avfoundation/avplayer
- VNGenerateForegroundInstanceMaskRequest: https://developer.apple.com/documentation/vision/vngenerateforegroundinstancemaskrequest
- VNInstanceMaskObservation: https://developer.apple.com/documentation/vision/vninstancemaskobservation
- WWDC23 Lift subjects from images: https://developer.apple.com/videos/play/wwdc2023/10176/
- fileImporter: https://developer.apple.com/documentation/swiftui/view/fileimporter(ispresented:allowedcontenttypes:allowsmultipleselection:oncompletion:)
- ShareLink: https://developer.apple.com/documentation/swiftui/sharelink

Vision: la máscara tiene instancias separadas; el label 0 es fondo; un tap se puede mapear a una instancia con coordenadas normalizadas. Corré Vision fuera del main thread. Mantené todo on-device.

## Rendimiento y progreso

- Operación por medio con fases identificables y cancelación.
- Cero trabajo pesado en MainActor: Vision, extracción, re-encode, archive.
- El filmstrip se carga con concurrencia limitada y nunca bloquea Trim.
- `AVPlayer` se pausa/cancela al cerrar; limpiá observers y tasks.
- Extraé las muestras una sola vez y reutilizalas; no regeneres thumbnails en cada drag.
- Medición por etapa solo en Debug, sin fotos ni contenido en logs.
- Límites de memoria, `autoreleasepool` por frame, cancelación cooperativa.
- Si el encoder no reporta progreso interno, mostrá estado indeterminado `Optimizing WebP…`, nunca 100%.

## Settings reales, no decorativas

Opciones que existan y se persistan: calidad/fps por defecto, confirmación de Intelligent Cut, conservar fuente para re-edición, modo de export (WhatsApp o archivo), limpieza de temporales/cache, privacidad/licencias. Nada de toggles que no afecten el código. Mostrá versión/build reales y estado de almacenamiento.

## Arquitectura y deuda técnica a resolver

- Los blobs binarios (`stickerData`, `previewData`) hoy van dentro de `packs.json`. Movelos a archivos por sticker y dejá solo metadata/ids en JSON, para que el archivo no crezca sin límite.
- No hay target de tests (`testTargets: []`). Agregá un target de unit tests y cubrí: mapeo de coordenadas de selección/crop, presupuesto del encoder animado, round-trip de `.stickreatepack`, y reglas de validación de pack. Es la forma de que "profesional" sea verificable.
- Si copiás código de XCAWAStickerMaker (MIT), incluí la atribución correspondiente.

## Benchmark representativo

No afirmes haber investigado literalmente todas las apps. Usá estas y, antes de adoptar dependencias o copiar código, verificá versión y licencia actuales.

- Sticker.ly: packs, cutout de foto, captions, Auto Cut de video, export a WhatsApp/Telegram, packs por link/código. Buena referencia para flujo corto; sus reseñas critican lentitud y bugs, no copies eso. https://apps.apple.com/us/app/sticker-ly-sticker-maker/id1458740001 y https://sticker.ly/
- Sticker Maker Studio: fotos, GIF/video, editor con fondo/texto/efectos, cámara, packs/comunidad. Reseñas reportan fallos de Smart Select; prioridad a precisión y no perder trabajo. https://apps.apple.com/us/app/sticker-maker-studio/id1443326857
- WhatSticker / Sticker Keyboard: Magic Selector de fondo, texto/emoji, animados desde Giphy/video, cámara. https://apps.apple.com/us/app/whatsticker-sticker-maker/id1147094379
- XCAWAStickerMaker (MIT): demo de una pantalla, 30 slots, badge, estados vacío/progreso/error, menú por tile, toggle global original/cutout. Copiá la claridad de estados, no el modelo fijo. https://github.com/alfianlosari/XCAWAStickerMaker
- VideoEditorKit: editor completo que exporta video; no se halló API pública de extracción de frames ni fps. No adoptar sin reevaluar. https://github.com/didisouzacosta/VideoEditorKit

## Plan de entrega obligatorio

Antes de cambios: revisá `git status`, versión y estructura. Entregá un diagnóstico breve P0/P1 con referencias archivo/símbolo. Implementá por fases:

1. P0: estabilidad, progreso real, crash de video, crop/coordenadas, no perder datos.
2. P1: flujo foto/Intelligent Cut/Adjust con keep/remove y crop; video trim/performance según las capturas.
3. P1: edición tras guardar, multi-selección/cola, share-in con selector de pack si la arquitectura lo permite.
4. P2: pack management, Settings reales, densidad de UI, accesibilidad, tests, deuda técnica.

Build local/CI (el `.xcodeproj` se genera):

```
brew install xcodegen
xcodegen generate
xcodebuild archive -project Stickreate.xcodeproj -scheme Stickreate \
  -configuration Release -destination "generic/platform=iOS" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM=""
```

Si no tenés macOS, hacé push a una rama de trabajo y esperá el workflow antes de declarar éxito.

No cambies el mínimo iOS 26 ni Liquid Glass sin justificar. No elimines requisitos del usuario: sin borde blanco, privado/on-device, fondo opcional, pack mixto en la app, edición por elemento, botón de export visible.

## Criterios de aceptación

1. Importar una foto NO quita el fondo automáticamente.
2. Intelligent Cut es opcional, on-device, con progreso; se pueden seleccionar/deseleccionar instancias y refinar la máscara.
3. Rectangle, Lasso, Brush, Erase, Full, Crop, Undo y Redo funcionan sobre coordenadas correctas en cualquier zoom/orientación.
4. Se puede marcar qué queda y qué se quita; Apply guarda crop, máscara, emojis y fuente; cancelar conserva el original.
5. Multi-select con cola editable: editar, deseleccionar, quitar, añadir más y reintentar sin perder el resto.
6. Trim se ve como la referencia: preview + filmstrip real + selection window blanca de dos handles + exterior dimmed + Next.
7. Video con Intelligent Cut apagado no ejecuta Vision; encendido reporta progreso real y no bloquea la UI.
8. Crear video no crashea con 10 s, fps alto y 4K; memoria y duración medidas en device.
9. El progreso nunca queda en 100% mientras comprime; errores/cancelación son recuperables.
10. Un sticker editado reemplaza al original en el mismo orden, con emojis y cover intactos, y sus cambios persisten.
11. Export respeta límites y ofrece dos exportaciones para pack mixto, con botón prominente y un solo open.
12. `.stickreatepack` round-trip preserva bytes, metadata y orden; datos malformados se rechazan.
13. Cámara con permisos bien manejados. Share-in solo se anuncia si se probó en device.
14. Tests/CI pasan; QA manual en iPhone cubre LiveContainer e instalación normal.

## Instrucción final

No respondas solo con un plan. Revisá, implementá, compilá, arreglá y validá las fases. Si algo depende de una prueba en iPhone, decilo exacto y dejá los pasos. Cambios mínimos por fase. Terminá con el link del build/release comprobado y una descripción corta de qué puede probar el usuario.
