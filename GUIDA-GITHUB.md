# Installare Scatto Guidato senza Mac

GitHub compila l'app sui suoi Mac nel cloud (gratis), tu la installi sull'iPhone dal PC Windows con Sideloadly.

## Parte 1 — Compilare su GitHub

1. Crea un account gratuito su **github.com** (Sign up).
2. In alto a destra tocca **+ > New repository**.
   - Nome: `ScattoGuidato`
   - Scegli **Private**
   - Lascia tutto il resto com'è e premi **Create repository**.
3. Nella pagina del repository vuoto clicca il link **uploading an existing file**.
4. Apri la cartella `ScattoGuidato` decompressa dallo zip. Seleziona **tutto il suo contenuto** (le cartelle `ScattoGuidato`, `ScattoGuidato.xcodeproj`, `.github` e i file `.md`) e trascinalo nella pagina del browser. Usa Chrome o Edge, così le cartelle mantengono la loro struttura.
5. In fondo premi **Commit changes**.
6. Controlla che nella lista dei file compaia la cartella `.github`. Se non c'è, vai al passo "Se la cartella .github non si è caricata" più sotto.
7. Apri la scheda **Actions** in alto. Vedrai l'esecuzione "Compila app iOS" partita da sola (pallino giallo = in corso, spunta verde = fatto). Ci mettono circa 5-10 minuti.
8. Quando c'è la spunta verde, cliccaci sopra e in fondo alla pagina, sotto **Artifacts**, scarica **ScattoGuidato-ipa**. È uno zip: estrailo e otterrai `ScattoGuidato.ipa`.

Per ricompilare dopo una modifica basta caricare i file aggiornati: la compilazione riparte da sola. Puoi anche avviarla a mano da **Actions > Compila app iOS > Run workflow**.

Se compare una **X rossa**, apri l'esecuzione, clicca il passo fallito, copia le righe con `error:` e mandamele.

### Se la cartella .github non si è caricata

1. Scheda **Actions** > **set up a workflow yourself**.
2. Cambia il nome del file in `compila-ios.yml`.
3. Cancella il contenuto proposto, incolla quello del file `.github/workflows/compila-ios.yml` dello zip (aprilo con Blocco note).
4. Premi **Commit changes**: la compilazione parte.

## Parte 2 — Installare sull'iPhone con Sideloadly

1. Sul PC installa **iTunes** e **iCloud** dal sito Apple (apple.com/itunes e la pagina di download di iCloud per Windows), **non** dal Microsoft Store. Se le hai dallo Store, disinstallale prima.
2. Scarica e installa Sideloadly **solo** da **sideloadly.io**.
3. Collega l'iPhone col cavo, sbloccalo e tocca **Autorizza** quando chiede di fidarsi del computer.
4. Apri Sideloadly:
   - trascina `ScattoGuidato.ipa` nella finestra;
   - scegli il tuo iPhone nell'elenco dei dispositivi;
   - scrivi il tuo Apple ID (va bene quello normale);
   - premi **Start** e inserisci la password ed eventualmente il codice di verifica.
5. Sull'iPhone:
   - Impostazioni > Privacy e sicurezza > **Modalità sviluppatore** > attiva e riavvia;
   - Impostazioni > Generali > **VPN e gestione dispositivi** > tocca il tuo Apple ID > **Autorizza**.
6. Apri **Scatto Guidato**, incolla la chiave API (da console.anthropic.com) e prova.

Con l'Apple ID gratuito l'app vale 7 giorni. Per rinnovarla rifai il passo 4, oppure attiva in Sideloadly il rinnovo automatico (l'iPhone deve essere collegato o sulla stessa rete Wi-Fi del PC).
