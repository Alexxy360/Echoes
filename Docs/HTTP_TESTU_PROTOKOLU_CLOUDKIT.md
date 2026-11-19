# Podpisany transport próby Development — CK-05a.4f

19 listopada 2026. **Adapter biblioteczny przygotowany i sprawdzany lokalnie; CLI/permit oraz rzeczywista próba Apple pozostają do przygotowania.** Nie rejestrowano klucza, nie zmieniano roli, nie przekazywano sekretu i nie uruchamiano usługi. Zatwierdzony model Individual pozostaje oddzielny od zgody na te operacje.

`gateway/scripts/community-protocol-transport.mjs` łączy silnik CK-05a.4e z istniejącym `CloudKitDevelopmentSigner`. Przechowuje wyłącznie przekazany obiekt signera; nie czyta pliku klucza lub zmiennych aktywacji. Import modułu niczego nie uruchamia. `isEnabled` domyślnie odmawia; musi zwrócić dokładnie true.

## Dokładny zakres żądań

Konstruktor weryfikuje plan i jego SHA. Dopuszcza tylko `records/lookup` oraz `records/modify`, po1–8 unikatowych ID z tego inwentarza. Odrzuca globalny checkpoint, dodatkowe ID, query i assets/upload.

Create ma dokładne początkowe pola i typy z planu, bez change tag. Replace ma dokładnie własną pustą barierę albo zaplanowany syntetyczny kolejny checkpoint oraz tag. Delete ma tylko nazwę/typ/tag. Nie przyjmuje forceDelete, mieszanych rodzajów mutacji, dodatkowych pól nawet z null, pominiętego typu pola, zmiany wartości lub atomowego batch. Wartości LOCATION mają dokładnie dwa zaplanowane składniki. Nie jest to interfejs do przesyłania dowolnych operacji użytkownika aplikacji.

Podpisuje bazowa implementacja istniejącego signera, a skonstruowany Request musi mieć POST, redirect manual i dokładny URL `https://api.apple-cloudkit.com/database/1/iCloud.mpvEcho.Echo/development/public/<dozwolona-operacja>`. Signer skonfigurowany dla innego kontenera jest odrzucany przed fetch. Nagłówki i bajty podpisu sprawdzono niezależnym verify z efemerycznym kluczem testowym. To nie sprawdza akceptacji nowego klucza przez Apple.

## Odpowiedź i rzeczywisty koniec pracy

Jednocześnie może trwać jedno wywołanie. Każde ma własny AbortController i timer8 sekund, połączony z sygnałem silnika. Adapter sprawdza enabled/signal przed fetch, podczas odczytu i przed zwróceniem wyniku.

Odpowiedź wymaga poprawnego HTTP2xx, JSON i body; odpowiedzi przekierowane są odrzucane. Content-Length musi być poprawnym nieujemnym zapisem dziesiętnym nie większym niż65536, jeżeli występuje. Rzeczywisty strumień ma limit64KiB i1024 fragmenty, także dla fragmentów zerowej długości; dekoder UTF-8 jest fatal. Błędy transportu/parsera nie udostępniają surowej treści odpowiedzi. Sprawdzenie rekordów i ochrona EXISTS pozostają w silniku, dlatego częściowa poprawnie zdekodowana odpowiedź trafia do jego kontroli.

Slot i pending Promise pozostają zajęte do rzeczywistego zakończenia fetch, odczytu i cancellation. Wczesne abort nie odblokowuje drugiego żądania. `waitForPendingOperations()` czeka na te Promise. Błąd cancellation ustawia nieodwracalny dla tego obiektu stan niepotwierdzonego drain: kolejne IO i pozytywne potwierdzenie drain są odrzucane. Silnik zachowuje wtedy lease i cleanup-pending. Nie ma resetu flagi pozwalającego zignorować błąd.

## Weryfikacja

11 nowych funkcji testowych: dziewięć podpisanych requestów całego silnika przez prawdziwy parser JSON do jawnego modelu providera; zamknięty default; odrzucenie zmienionego inwentarza/typów/pól/tagów i innego kontenera; błędne HTTP/Content-Length/JSON/UTF-8; granica64KiB i fragmenty; niekooperujący fetch; oczekiwanie na cancellation; odrzucenie nieudanego cancellation; revoke oraz rzeczywisty native fetch i dwa lokalne serwery HTTP. Serwer docelowy przekierowania nie dostał żadnego żądania ani podpisanych nagłówków.

Końcowe pełne przebiegi: **679/679 Node22.23.5 i679/679 Node24.22.1**. Wyniki i SHA: [raport lokalny](evidence/community-protocol-http-local-tests.json). Provider jest syntetyczny, klucz efemeryczny tylko w pamięci; dwa serwery są loopback. Nie wykonano Apple S2S, testów ról/kont, uploadu assetów ani Cloudflare. Kod produktu iOS/gateway, zależności i CI niezmienione; nie powtarzano kompilacji/testów iOS.

Następnie: CLI ze sprawdzanym lokalnym planem/permit i bezpiecznym zapisem raportu, testy bramek uruchomienia i recovery. Dopiero gotowy konkretny zakres pozwoli uzyskać zgodę na wycofanie starego klucza diagnostycznego, nowy klucz Development, rolę i jedną próbę syntetycznych rekordów. Nie uznajemy modelu za odbiór Apple lub gotowość TestFlight.
