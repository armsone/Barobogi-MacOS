// Barobogi 원화 환산 — 공용 파서·환율 저장소(Chrome·Whale·Safari 배경, 내용 스크립트, 팝업, Mac 메일 보기 공용).
// - 파서: 외국 금액을 찾아 원화 환산을 계산한다. 날짜·버전·금액이 아닌 숫자와 원화(KRW) 금액은 건드리지 않는다.
//   모호한 기호($·¥·元·peso 등)는 명시 통화 코드·국가/언어 단서가 있을 때만 정하고, 없으면 건너뛴다(잘못된 나라로 바꾸지 않음).
// - 저장소(배경만): 고정된 공개 환율 주소 3곳에서 익명 GET만 한다. 페이지 글자·이미지·주소·사용자 식별자는 보내지 않는다.
//   마지막 '유효한' 환율만 저장해 두고(실패·불량 응답은 덮어쓰지 않음) 번역된 내용은 저장하지 않는다.
// 이 파일은 DOM을 쓰지 않는다(서비스 워커·이벤트 페이지·내용 스크립트·WKWebView 사용자 스크립트에서 같은 코드로 로드).
(() => {
  "use strict";
  if (globalThis.BarobogiFX) return;

  // MARK: 상수

  const PRIMARY_URL = "https://api.exchangerate.dev/v1/latest?base=USD";
  const FALLBACK_URLS = [
    "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/usd.min.json",
    "https://latest.currency-api.pages.dev/v1/currencies/usd.min.json"
  ];
  const ATTRIBUTION_TEXT = "Rates by Exchangerate.dev";
  // 제공사 약관상 출처 표기 링크(한 곳에서만 바꾼다).
  const ATTRIBUTION_URL = "https://exchangerate.dev";
  const CACHE_KEY = "smt_fx_cache_v1";
  const DAILY_KEY = "smt_fx_daily_v1";
  const ATTEMPT_KEY = "smt_fx_attempt_v1";
  const REFRESH_INTERVAL = 15 * 60 * 1000;
  const NO_CACHE_RETRY = 60 * 1000;
  const SAVED_AFTER = 20 * 60 * 1000;
  const ENDPOINT_TIMEOUT = 6000;
  const MAX_BODY = 2000000;
  const NO_RATE_MESSAGE = "환율을 한 번 받아야 원화 환산을 사용할 수 있습니다";

  // ISO 4217 법정 통화 코드(가상자산·귀금속·SDR 등은 넣지 않는다). 환율 값은 제공사 응답에서만 온다.
  const FIAT = new Set(("AED AFN ALL AMD ANG AOA ARS AUD AWG AZN BAM BBD BDT BGN BHD BIF BMD BND BOB BRL BSD BTN BWP BYN BZD " +
    "CAD CDF CHF CLP CNY COP CRC CUP CVE CZK DJF DKK DOP DZD EGP ERN ETB EUR FJD FKP GBP GEL GHS GIP GMD GNF GTQ GYD HKD HNL " +
    "HTG HUF IDR ILS INR IQD IRR ISK JMD JOD JPY KES KGS KHR KMF KPW KRW KWD KYD KZT LAK LBP LKR LRD LSL LYD MAD MDL MGA MKD " +
    "MMK MNT MOP MRU MUR MVR MWK MXN MYR MZN NAD NGN NIO NOK NPR NZD OMR PAB PEN PGK PHP PKR PLN PYG QAR RON RSD RUB RWF SAR " +
    "SBD SCR SDG SEK SGD SHP SLE SLL SOS SRD SSP STN SVC SYP SZL THB TJS TMT TND TOP TRY TTD TWD TZS UAH UGX USD UYU UZS VES " +
    "VND VUV WST XAF XCD XCG XOF XPF YER ZAR ZMW ZWG ZWL").split(" "));
  // 영어 낱말·회사명과 겹치는 코드는 금액 앞/뒤 어디든 읽되, 비금액 문맥("TOP 10 products", "5 AMD Ryzen")만 nonMoneyIso가 걸러 낸다.
  const WORDLIKE = new Set(["ALL", "TOP", "TRY", "MAD", "PEN", "SOS", "CUP", "COP", "BAM", "AMD", "LAK", "ANG", "BIF"]);
  const ZERO_DECIMAL = new Set(["JPY", "KRW", "VND", "IDR", "CLP", "PYG", "UGX", "RWF", "XAF", "XOF", "XPF", "KMF", "GNF", "DJF",
    "BIF", "VUV", "ISK"]);
  const THREE_DECIMAL = new Set(["BHD", "KWD", "OMR", "JOD", "TND", "IQD", "LYD"]);
  // 점(.)을 천 단위 구분으로 쓰는 쪽이 일반적인 통화(소수 쉼표 지역).
  const DOT_GROUPING = new Set(["EUR", "IDR", "VND", "BRL", "TRY", "ARS", "CLP", "COP", "PLN", "CZK", "HUF", "DKK", "RUB", "RON",
    "UAH", "HRK", "BGN", "PYG", "UYU"]);
  const DECIMAL_COMMA_LANGS = new Set(["de", "fr", "es", "it", "pt", "nl", "ru", "id", "vi", "tr", "pl", "cs", "sk", "sv", "da",
    "nb", "no", "fi", "hu", "ro", "bg", "uk", "hr", "sl", "el", "ca", "ms"]);
  const DECIMAL_COMMA_COUNTRIES = new Set(["DE", "FR", "ES", "IT", "PT", "BR", "NL", "RU", "ID", "VN", "TR", "PL", "CZ", "SK",
    "SE", "DK", "NO", "FI", "HU", "RO", "BG", "UA", "HR", "SI", "GR", "AR", "CL", "CO", "UY", "AT", "BE"]);
  // '$'를 미국 달러로 보는 언어(문서화된 가정): 영어(미국 외 지역 단서 없을 때)·한국어·일본어·중국어(본토)·독일어·프랑스어·이탈리아어·네덜란드어.
  const USD_DEFAULT_LANGS = new Set(["en", "ko", "ja", "zh", "de", "fr", "it", "nl"]);
  const COUNTRY_DOLLAR = { US: "USD", CA: "CAD", AU: "AUD", NZ: "NZD", HK: "HKD", SG: "SGD", TW: "TWD", MX: "MXN", AR: "ARS",
    CL: "CLP", CO: "COP", UY: "UYU", CU: "CUP", DO: "DOP", PH: "PHP", LR: "LRD", FJ: "FJD", BS: "BSD", BB: "BBD", BZ: "BZD",
    BM: "BMD", BN: "BND", JM: "JMD", NA: "NAD", SB: "SBD", SR: "SRD", TT: "TTD", ZW: "ZWL" };
  const COUNTRY_PESO = { PH: "PHP", MX: "MXN", AR: "ARS", CL: "CLP", CO: "COP", UY: "UYU", CU: "CUP", DO: "DOP" };
  const COUNTRY_RUPEE = { IN: "INR", PK: "PKR", LK: "LKR", NP: "NPR", MU: "MUR", SC: "SCR" };
  // 통화 코드로 쓰이지 않는 국가 코드 최상위 도메인(국가 단서에서 제외)
  const NON_COUNTRY_TLDS = new Set(["io", "ai", "tv", "me", "co", "fm", "ly", "to", "ws", "cc", "gg", "gl", "sh", "ac", "am", "ms", "so", "ee"]);

  // 기호·표기 → 통화 키. 키는 통화 코드이거나 모호 표기(AMB_*). 긴 것부터 맞춘다.
  const AMB = { DOLLAR: "AMB_DOLLAR", YEN: "AMB_YEN", YUAN: "AMB_YUAN", PESO: "AMB_PESO", RUPEE: "AMB_RUPEE", FRANC: "AMB_FRANC" };
  const SYMBOLS = [
    ["US$", "USD"], ["US＄", "USD"], ["CA$", "CAD"], ["CAD$", "CAD"], ["CDN$", "CAD"], ["C$", "CAD"], ["AU$", "AUD"], ["A$", "AUD"],
    ["NZ$", "NZD"], ["HK$", "HKD"], ["HK＄", "HKD"], ["NT$", "TWD"], ["NT＄", "TWD"], ["TW$", "TWD"], ["SG$", "SGD"], ["S$", "SGD"],
    ["R$", "BRL"], ["MX$", "MXN"], ["Mex$", "MXN"], ["Rp.", "IDR"], ["Rp", "IDR"], ["RM", "MYR"], ["Php", "PHP"], ["₱", "PHP"],
    ["€", "EUR"], ["£", "GBP"], ["₹", "INR"], ["฿", "THB"], ["₫", "VND"], ["₽", "RUB"], ["₺", "TRY"], ["₪", "ILS"], ["₴", "UAH"],
    ["₦", "NGN"], ["₭", "LAK"], ["₸", "KZT"], ["₾", "GEL"], ["₼", "AZN"], ["₡", "CRC"], ["₲", "PYG"], ["₵", "GHS"],
    ["zł", "PLN"], ["Kč", "CZK"], ["円", "JPY"], ["圓", "JPY"], ["엔", "JPY"],
    ["人民币", "CNY"], ["人民幣", "CNY"], ["人民元", "CNY"], ["日元", "JPY"], ["日圆", "JPY"], ["日圓", "JPY"],
    ["新台币", "TWD"], ["新台幣", "TWD"], ["新臺幣", "TWD"], ["台币", "TWD"], ["台幣", "TWD"], ["港币", "HKD"], ["港幣", "HKD"], ["港元", "HKD"],
    ["¥", AMB.YEN], ["￥", AMB.YEN], ["$", AMB.DOLLAR], ["＄", AMB.DOLLAR], ["元", AMB.YUAN]
  ];
  // 낱말 표기(금액 뒤). [표기, 키, 종류] 종류: l=라틴(대소문자 무시, 낱말 경계), h=한글(조사만 허용), k=가타카나, c=한자/기타
  const WORDS = [
    ["new zealand dollars", "NZD", "l"], ["new zealand dollar", "NZD", "l"], ["hong kong dollars", "HKD", "l"], ["hong kong dollar", "HKD", "l"],
    ["singapore dollars", "SGD", "l"], ["singapore dollar", "SGD", "l"], ["canadian dollars", "CAD", "l"], ["canadian dollar", "CAD", "l"],
    ["australian dollars", "AUD", "l"], ["australian dollar", "AUD", "l"], ["new taiwan dollars", "TWD", "l"], ["taiwan dollars", "TWD", "l"],
    ["u.s. dollars", "USD", "l"], ["us dollars", "USD", "l"], ["us dollar", "USD", "l"], ["american dollars", "USD", "l"],
    ["philippine pesos", "PHP", "l"], ["philippine peso", "PHP", "l"], ["mexican pesos", "MXN", "l"], ["mexican peso", "MXN", "l"],
    ["argentine pesos", "ARS", "l"], ["argentine peso", "ARS", "l"], ["chilean pesos", "CLP", "l"], ["chilean peso", "CLP", "l"],
    ["colombian pesos", "COP", "l"], ["colombian peso", "COP", "l"],
    ["indian rupees", "INR", "l"], ["indian rupee", "INR", "l"], ["pakistani rupees", "PKR", "l"], ["swiss francs", "CHF", "l"], ["swiss franc", "CHF", "l"],
    ["british pounds", "GBP", "l"], ["british pound", "GBP", "l"], ["pounds sterling", "GBP", "l"], ["pound sterling", "GBP", "l"],
    ["turkish lira", "TRY", "l"], ["thai baht", "THB", "l"], ["chinese yuan", "CNY", "l"], ["renminbi", "CNY", "l"],
    ["dollars", AMB.DOLLAR, "l"], ["dollar", AMB.DOLLAR, "l"], ["euros", "EUR", "l"], ["euro", "EUR", "l"], ["yen", "JPY", "l"],
    ["yuan", AMB.YUAN, "l"], ["baht", "THB", "l"], ["rupiah", "IDR", "l"], ["ringgit", "MYR", "l"], ["zloty", "PLN", "l"],
    ["rubles", "RUB", "l"], ["roubles", "RUB", "l"], ["ruble", "RUB", "l"], ["pesos", AMB.PESO, "l"], ["peso", AMB.PESO, "l"],
    ["rupees", AMB.RUPEE, "l"], ["rupee", AMB.RUPEE, "l"], ["francs", AMB.FRANC, "l"], ["franc", AMB.FRANC, "l"],
    ["미국 달러", "USD", "h"], ["캐나다 달러", "CAD", "h"], ["호주 달러", "AUD", "h"], ["오스트레일리아 달러", "AUD", "h"], ["뉴질랜드 달러", "NZD", "h"],
    ["홍콩 달러", "HKD", "h"], ["싱가포르 달러", "SGD", "h"], ["대만 달러", "TWD", "h"], ["신타이완 달러", "TWD", "h"], ["달러", AMB.DOLLAR, "h"],
    ["필리핀 페소", "PHP", "h"], ["멕시코 페소", "MXN", "h"], ["아르헨티나 페소", "ARS", "h"], ["칠레 페소", "CLP", "h"], ["콜롬비아 페소", "COP", "h"],
    ["페소", AMB.PESO, "h"], ["인도 루피", "INR", "h"], ["파키스탄 루피", "PKR", "h"], ["루피아", "IDR", "h"], ["루피", AMB.RUPEE, "h"],
    ["스위스 프랑", "CHF", "h"], ["프랑", AMB.FRANC, "h"], ["영국 파운드", "GBP", "h"], ["파운드", "GBP", "h"], ["유로", "EUR", "h"],
    ["위안", AMB.YUAN, "h"], ["바트", "THB", "h"], ["링깃", "MYR", "h"], ["루블", "RUB", "h"], ["엔", "JPY", "h"],
    ["米ドル", "USD", "k"], ["豪ドル", "AUD", "k"], ["カナダドル", "CAD", "k"], ["香港ドル", "HKD", "k"], ["シンガポールドル", "SGD", "k"],
    ["ニュージーランドドル", "NZD", "k"], ["新台湾ドル", "TWD", "k"], ["台湾ドル", "TWD", "k"], ["フィリピンペソ", "PHP", "k"], ["ドル", AMB.DOLLAR, "k"],
    ["ユーロ", "EUR", "k"], ["ポンド", "GBP", "k"], ["バーツ", "THB", "k"], ["ペソ", AMB.PESO, "k"], ["ルピア", "IDR", "k"], ["リンギット", "MYR", "k"],
    ["美元", "USD", "c"], ["美金", "USD", "c"], ["欧元", "EUR", "c"], ["歐元", "EUR", "c"], ["英镑", "GBP", "c"], ["英鎊", "GBP", "c"],
    ["泰铢", "THB", "c"], ["泰銖", "THB", "c"], ["澳元", "AUD", "c"], ["加元", "CAD", "c"], ["新加坡元", "SGD", "c"]
  ];
  // 금액 '앞'에는 붙지 않는 표기(뒤에서만 읽는다): "20엔 3유로"에서 앞 단위의 '엔'이 뒤 숫자의 접두 기호로 읽히는 오인을 막는다.
  const SUFFIX_ONLY_SYMBOLS = new Set(["円", "圓", "엔", "元", "日元", "日圆", "日圓", "港元", "zł", "Kč"]);
  const SYMBOLS_SORTED = SYMBOLS.slice().sort((a, b) => b[0].length - a[0].length);
  const WORDS_SORTED = WORDS.slice().sort((a, b) => b[0].length - a[0].length);
  const HANGUL_PARTICLES = "은는이가을를에의도로과와만화께";
  const GROUP_SPACES = "     ";
  const UNIT_VALUES = { "万": 1e4, "萬": 1e4, "億": 1e8, "亿": 1e8, "兆": 1e12, "千": 1e3, "만": 1e4, "억": 1e8, "조": 1e12, "천": 1e3 };

  // MARK: 문자 도우미

  function digitValue(ch) {
    if (!ch) return -1;
    const c = ch.charCodeAt(0);
    if (c >= 48 && c <= 57) return c - 48;
    if (c >= 0xFF10 && c <= 0xFF19) return c - 0xFF10;
    return -1;
  }
  const isDigit = (ch) => digitValue(ch) >= 0;
  const isLatinLetter = (ch) => !!ch && /[A-Za-z]/.test(ch);
  const isLetterOrDigit = (ch) => !!ch && (isDigit(ch) || /[\p{L}\p{N}]/u.test(ch));
  const isSpaceChar = (ch) => !!ch && GROUP_SPACES.includes(ch);

  // MARK: 문맥(언어·나라 단서)

  /** { htmlLang, host, textLang, text } → { lang, script, country, kana, decimalComma }. 모두 선택값이며 없으면 단서 없음. */
  function makeContext(input = {}) {
    const tag = String(input.textLang || input.htmlLang || "").replace(/_/g, "-");
    const parts = tag.split("-");
    const lang = (parts[0] || "").toLowerCase();
    let script = "";
    let region = "";
    for (const part of parts.slice(1)) {
      if (/^[A-Za-z]{4}$/.test(part)) script = part.toLowerCase();
      else if (/^[A-Za-z]{2}$/.test(part)) region = part.toUpperCase();
    }
    if (lang === "zh") {
      if (!script) script = region === "TW" || region === "HK" || region === "MO" ? "hant" : "hans";
    }
    // 텍스트 언어에 지역이 없으면 문서 언어의 지역을 쓴다(예: html lang="en-PH").
    if (!region && input.htmlLang) {
      const m = String(input.htmlLang).replace(/_/g, "-").match(/-([A-Za-z]{2})(?:-|$)/);
      if (m) region = m[1].toUpperCase();
    }
    let country = region;
    if (!country && input.host) {
      const labels = String(input.host).toLowerCase().split(".");
      const tld = labels[labels.length - 1];
      if (tld && /^[a-z]{2}$/.test(tld) && !NON_COUNTRY_TLDS.has(tld)) country = tld === "uk" ? "GB" : tld.toUpperCase();
    }
    const kana = /[぀-ヿ]/.test(String(input.text || ""));
    const decimalComma = DECIMAL_COMMA_LANGS.has(lang) || (!lang && DECIMAL_COMMA_COUNTRIES.has(country));
    return { lang, script, country, kana, decimalComma };
  }

  // MARK: 기호 → 통화

  /** 모호 표기 해석. 단서가 없으면 null(건너뜀). word는 낱말 표기("달러" 등)에서 왔는지. */
  function resolveAmbiguous(key, ctx, word, hasKanaNear) {
    const country = ctx.country;
    switch (key) {
      case AMB.DOLLAR: {
        if (country && COUNTRY_DOLLAR[country] && country !== "PH") return COUNTRY_DOLLAR[country];
        if (country === "PH") return null; // 필리핀 문서의 '$'는 달러/페소 혼용 — 명시 코드 없으면 건너뜀
        // 한국어·일본어 글에서 '달러'/'ドル'는 미국 달러가 기본이다(문서화된 가정). '$' 기호도 같은 언어 문맥에서만 미국 달러로 본다.
        if (USD_DEFAULT_LANGS.has(ctx.lang)) {
          if (ctx.lang === "zh" && ctx.script === "hant" && !word) return null;
          return "USD";
        }
        return null;
      }
      case AMB.YEN:
        if (ctx.lang === "ja" || country === "JP" || ctx.kana || hasKanaNear) return "JPY";
        if ((ctx.lang === "zh" && ctx.script === "hans") || country === "CN") return "CNY";
        return null;
      case AMB.YUAN:
        if (country === "TW" || (ctx.lang === "zh" && ctx.script === "hant" && country !== "HK")) return "TWD";
        if (country === "HK") return "HKD";
        // 한국어·일본어 글의 '위안'/'元'은 중국 위안, 중국 본토 문맥의 '元'도 위안이다. 그 밖의 '元'은 건너뜀.
        if (ctx.lang === "ko" || ctx.lang === "ja" || ctx.lang === "zh" || country === "CN") return "CNY";
        return word ? "CNY" : null;
      case AMB.PESO:
        return country && COUNTRY_PESO[country] ? COUNTRY_PESO[country] : null; // 'peso'만으로는 필리핀으로 단정하지 않는다
      case AMB.RUPEE:
        return country && COUNTRY_RUPEE[country] ? COUNTRY_RUPEE[country] : null;
      case AMB.FRANC:
        return country === "CH" || country === "LI" ? "CHF" : null;
      default:
        return null;
    }
  }

  // MARK: 숫자 읽기

  /** 숫자 덩어리 읽기. text[i]는 숫자. { end, value } 또는 null(해석 불가·모호). currencyHint는 알려진 통화 코드(없으면 null). */
  function scanNumber(text, i, currencyHint, ctx) {
    const runs = [];
    const seps = [];
    let p = i;
    for (;;) {
      let q = p;
      let digits = "";
      while (q < text.length && isDigit(text[q])) { digits += String(digitValue(text[q])); q += 1; }
      runs.push(digits);
      p = q;
      const sep = text[p];
      if (!(sep && isDigit(text[p + 1]) && (sep === "," || sep === "." || sep === "'" || sep === "\u2019" || isSpaceChar(sep)))) break;
      if (isSpaceChar(sep)) {
        // 공백 구분은 "1~3자리 + 공백 + 정확히 세 자리" 묶음일 때만 이어 붙인다.
        let k = p + 1;
        let n = 0;
        while (k < text.length && isDigit(text[k])) { n += 1; k += 1; }
        const prev = runs[runs.length - 1];
        if (n !== 3 || (runs.length === 1 ? prev.length > 3 : prev.length !== 3)) break;
      }
      seps.push(isSpaceChar(sep) ? " " : (sep === "\u2019" ? "'" : sep));
      p += 1;
    }
    const end = p;
    if (runs.length === 1) return { end, value: Number(runs[0]) };
    const last = seps[seps.length - 1];
    const lastRun = runs[runs.length - 1];
    // 천 단위 묶음 검증: 첫 덩어리 1~3자리, 나머지 세 자리(쉼표는 인도식 2자리 묶음도 허용)
    const grouped = (list, kind) => {
      if (list[0].length < 1 || list[0].length > 3) return false;
      const rest = list.slice(1);
      if (rest.every((r) => r.length === 3)) return true;
      return kind === "," && rest.length >= 2 && rest[rest.length - 1].length === 3 && rest.slice(0, -1).every((r) => r.length === 2);
    };
    const kinds = new Set(seps);
    if (kinds.size === 1) {
      if (seps.length >= 2 || last === " " || last === "'") {
        return grouped(runs, last) ? { end, value: Number(runs.join("")) } : null;
      }
      // 구분 기호가 쉼표/점 하나뿐
      if (lastRun.length !== 3 || runs[0] === "0" || runs[0].length > 3) return { end, value: Number(runs[0] + "." + lastRun) };
      // 세 자리: 천 단위일 수도 소수일 수도 있다
      if (last === "." && THREE_DECIMAL.has(currencyHint)) return { end, value: Number(runs[0] + "." + lastRun) };
      if (last === ",") {
        const decimalLeaning = ctx.decimalComma && !ZERO_DECIMAL.has(currencyHint) && !DOT_GROUPING.has(currencyHint);
        return decimalLeaning ? null : { end, value: Number(runs[0] + lastRun) };
      }
      if (currencyHint && (ZERO_DECIMAL.has(currencyHint) || DOT_GROUPING.has(currencyHint))) return { end, value: Number(runs[0] + lastRun) };
      if (ctx.decimalComma) return { end, value: Number(runs[0] + lastRun) };
      return null; // 영어권 '1.000 USD'는 천 단위/소수를 구분할 수 없으므로 건너뜀
    }
    // 서로 다른 기호가 섞임: 마지막 기호(쉼표/점)가 소수점, 앞은 모두 같은 천 단위 기호
    if (last !== "," && last !== ".") return null;
    const groupSeps = seps.slice(0, -1);
    if (new Set(groupSeps).size !== 1 || groupSeps[0] === last) return null;
    const head = runs.slice(0, -1);
    if (!grouped(head, groupSeps[0])) return null;
    return { end, value: Number(head.join("") + "." + lastRun) };
  }

  /** 숫자 뒤의 万·億·만·억·천 연쇄("2万5千", "1.5万", "3억")를 곱해 준다. 없으면 그대로. */
  function applyCjkUnits(text, number) {
    let p = number.end;
    let u = UNIT_VALUES[text[p]];
    if (u === undefined) return number;
    let total = number.value * u;
    let lastUnit = u;
    p += 1;
    // 이어지는 "숫자+더 작은 단위"(2万5千, 1億2000万)
    for (;;) {
      let q = p;
      let digits = "";
      while (q < text.length && (isDigit(text[q]) || (text[q] === "," && isDigit(text[q + 1])))) {
        if (text[q] !== ",") digits += String(digitValue(text[q]));
        q += 1;
      }
      if (!digits) break;
      const unit = UNIT_VALUES[text[q]];
      if (unit !== undefined && unit < lastUnit) {
        total += Number(digits) * unit;
        lastUnit = unit;
        p = q + 1;
        continue;
      }
      if (unit === undefined && lastUnit >= 1e4 && digits.length <= 4 && Number(digits) < lastUnit) {
        total += Number(digits); // 3万5000円
        p = q;
      }
      break;
    }
    return { end: p, value: total, unit: true };
  }

  // MARK: 통화 표기 찾기

  function boundaryBefore(text, index) {
    const ch = text[index - 1];
    return !ch || !isLatinLetter(ch);
  }

  /** 금액 앞의 통화 표기. 최대 한 칸 공백을 건너뛴다. { start, key, iso } 또는 null. */
  function findPrefix(text, s) {
    let e = s;
    if (e > 0 && isSpaceChar(text[e - 1]) && text[e - 1] !== undefined) e -= 1;
    if (e > 0 && isSpaceChar(text[e - 1])) return null;
    for (const [sym, key] of SYMBOLS_SORTED) {
      if (SUFFIX_ONLY_SYMBOLS.has(sym)) continue;
      const start = e - sym.length;
      if (start < 0 || text.slice(start, e) !== sym) continue;
      if (/^[A-Za-z]/.test(sym) && !boundaryBefore(text, start)) continue;
      return { start, key, symbol: sym, spaced: e !== s };
    }
    if (e >= 3) {
      const code = text.slice(e - 3, e);
      if (/^[A-Z]{3}$/.test(code) && FIAT.has(code) && boundaryBefore(text, e - 3)) {
        return { start: e - 3, key: code, iso: true, spaced: e !== s };
      }
    }
    return null;
  }

  /** 명시 ISO 코드가 돈이 아닌 문맥(PHP 버전, "TOP 10 products", "5 AMD Ryzen")인지. */
  function nonMoneyIso(text, code, numStart, number, side, codeEnd) {
    if (side === "prefix") {
      const raw = text.slice(numStart, number.end);
      if (code === "PHP" && /^[5-8](\.\d+){0,2}$/.test(raw)) return true;
      if (WORDLIKE.has(code) && /^(3|5|10|20|25|50|100)$/.test(raw) && /^\s+[A-Za-z]{3,}/.test(text.slice(number.end, number.end + 20))) return true;
      return false;
    }
    return WORDLIKE.has(code) && /^\s+[A-Z][A-Za-z]+/.test(text.slice(codeEnd, codeEnd + 20));
  }

  /** 금액 뒤의 통화 표기. { end, key, iso, word } 또는 null. */
  function findSuffix(text, e) {
    let p = e;
    if (isSpaceChar(text[p])) p += 1;
    const rest = text.slice(p, p + 24);
    if (!rest) return null;
    const code = rest.slice(0, 3);
    if (/^[A-Z]{3}$/.test(code) && FIAT.has(code) && !isLetterOrDigit(text[p + 3]) && (!isLatinLetter(text[p + 3]))) {
      return { end: p + 3, key: code, iso: true };
    }
    const lower = rest.toLowerCase();
    for (const [word, key, kind] of WORDS_SORTED) {
      if (kind === "l") {
        if (!lower.startsWith(word)) continue;
        const after = rest[word.length];
        if (after && isLatinLetter(after)) continue;
      } else {
        if (!rest.startsWith(word)) continue;
        const after = rest[word.length];
        if (kind === "h" && after && /[가-힣]/.test(after) && !HANGUL_PARTICLES.includes(after)) continue;
        if (kind === "k" && after && /[ァ-ヺ]/.test(after)) continue;
      }
      return { end: p + word.length, key, word: true };
    }
    for (const [sym, key] of SYMBOLS_SORTED) {
      if (sym === "$" || sym === "＄") continue; // 금액 뒤 '$'는 쓰지 않는다
      if (!rest.startsWith(sym)) continue;
      const after = rest[sym.length];
      if (/^[A-Za-z]/.test(sym) && isLatinLetter(after)) continue;
      if ((sym === "엔" || sym === "元") && after && /[가-힣]/.test(after) && !HANGUL_PARTICLES.includes(after)) continue;
      return { end: p + sym.length, key, word: false, symbol: sym };
    }
    if (rest.startsWith("Ft") && !isLatinLetter(rest[2])) return { end: p + 2, key: "HUF" };
    return null;
  }

  /** 영어 단위(million 등)는 통화 기호·코드가 앞에 있을 때만. */
  function applyEnglishUnits(text, number) {
    const m = text.slice(number.end, number.end + 12).match(/^\s?(trillion|billion|million|thousand|bn|mn|tn|k|m|b)(?![A-Za-z])/i);
    if (!m) return number;
    const w = m[1].toLowerCase();
    const mult = { trillion: 1e12, tn: 1e12, billion: 1e9, bn: 1e9, b: 1e9, million: 1e6, mn: 1e6, m: 1e6, thousand: 1e3, k: 1e3 }[w];
    return { end: number.end + m[0].length, value: number.value * mult, unit: true };
  }

  const KRW_AFTER = /^\s*[\(（\[]?\s*(?:약|≈|~|about|approx\.?)?\s*[\d,\.]+\s*(?:만|억|천)?\s*(?:원|KRW)/i;
  const RANGE_AFTER = /^\s*[-–—~〜～]\s*[\d０-９]/;

  /**
   * text 안의 외국 금액을 찾는다.
   * ctx: makeContext() 결과(없으면 단서 없음). krwPer: { 통화코드: 1단위당 원화 }.
   * 돌려주는 값: { mentions: [{start,end,code,amount,krw,text}], skipped: [{start,end,reason}] }
   * start~end는 통화 표기를 포함한 금액 전체의 문자열 범위다. 환산 주석은 end 바로 뒤에 붙인다.
   */
  function findAmounts(text, ctx, krwPer) {
    const mentions = [];
    const skipped = [];
    if (typeof text !== "string" || text.length < 2) return { mentions, skipped };
    ctx = ctx || makeContext();
    if (!/[\d０-９]/.test(text)) return { mentions, skipped };
    let i = 0;
    while (i < text.length) {
      const ch = text[i];
      if (!isDigit(ch)) { i += 1; continue; }
      const before = text[i - 1];
      // 다른 숫자·날짜·버전의 일부이거나 낱말 안의 숫자는 시작점이 아니다.
      if (before && (isDigit(before) || ((before === "." || before === "," || before === "-" || before === "/" || before === ":" || before === "·") && isDigit(text[i - 2])))) {
        while (i < text.length && (isDigit(text[i]) || text[i] === "." || text[i] === "," || text[i] === ":" || text[i] === "/" || text[i] === "-")) i += 1;
        continue;
      }
      const prefix = findPrefix(text, i);
      if (!prefix && before && isLatinLetter(before)) { i += 1; while (i < text.length && isDigit(text[i])) i += 1; continue; }
      // 금액 숫자 읽기(통화 힌트는 앞 표기가 코드일 때만 미리 알 수 있다)
      const hintPrefix = prefix && !String(prefix.key).startsWith("AMB_") ? prefix.key : null;
      let number = scanNumber(text, i, hintPrefix, ctx);
      if (!number) {
        // 모호하면 뒤쪽 표기로 한 번 더 시도
        const sufProbe = findSuffix(text, scanEndOf(text, i));
        const hint = sufProbe && !String(sufProbe.key).startsWith("AMB_") ? sufProbe.key : null;
        number = hint ? scanNumber(text, i, hint, ctx) : null;
      } else if (!hintPrefix) {
        const sufProbe = findSuffix(text, number.end);
        const hint = sufProbe && !String(sufProbe.key).startsWith("AMB_") ? sufProbe.key : null;
        if (hint && hint !== hintPrefix) {
          const again = scanNumber(text, i, hint, ctx);
          if (again) number = again;
        }
      }
      if (!number) {
        const skipEnd = scanEndOf(text, i);
        if (prefix || findSuffix(text, skipEnd)) skipped.push({ start: prefix ? prefix.start : i, end: skipEnd, reason: "number-ambiguous" });
        i = Math.max(skipEnd, i + 1);
        continue;
      }
      // 뒤 문자가 숫자 연속(1.2.3, 2026/10/17, 10-17-2026)이면 금액이 아니다.
      const tail = text[number.end];
      if ((tail === "." || tail === "," || tail === "/" || tail === "-" || tail === ":") && isDigit(text[number.end + 1])) {
        i = number.end + 1;
        while (i < text.length && (isDigit(text[i]) || text[i] === "." || text[i] === "," || text[i] === ":" || text[i] === "/" || text[i] === "-")) i += 1;
        continue;
      }
      number = applyCjkUnits(text, number);
      if (prefix && !number.unit) number = applyEnglishUnits(text, number);
      if (!isFinite(number.value) || number.value <= 0 || number.value >= 1e15) { i = Math.max(number.end, i + 1); continue; }

      const suffix = findSuffix(text, number.end);
      let key = null;
      let startIdx = prefix ? prefix.start : i;
      let endIdx = number.end;
      let wordForm = false;
      let isoSide = "";
      if (suffix && suffix.iso) {
        isoSide = "suffix";
        key = suffix.key;
        endIdx = suffix.end;
        wordForm = true;
      } else if (prefix && prefix.iso) {
        isoSide = "prefix";
        key = prefix.key;
      } else if (prefix) {
        key = prefix.key;
        // "人民币100元", "€100 EUR"처럼 같은 통화를 뒤에서 한 번 더 말하면 그 끝까지가 금액이다.
        if (suffix && !suffix.iso && (suffix.key === prefix.key || (prefix.key === "CNY" && suffix.key === AMB.YUAN))) endIdx = suffix.end;
        // "$100 US dollars" 같은 보강: 뒤 표기가 모호하지 않으면 그것을 우선
        if (suffix && !String(suffix.key).startsWith("AMB_") && String(prefix.key).startsWith("AMB_") && suffix.word) {
          key = suffix.key;
          endIdx = suffix.end;
        }
      } else if (suffix) {
        key = suffix.key;
        endIdx = suffix.end;
        wordForm = !!suffix.word;
      }
      if (!key) { i = Math.max(number.end, i + 1); continue; }
      if (isoSide && nonMoneyIso(text, key, i, number, isoSide, endIdx)) { i = Math.max(endIdx, i + 1); continue; }
      // 앞쪽 통화 기호 앞에 ISO 코드가 더 있으면("USD $100") 명시 코드가 이긴다.
      if (prefix && !prefix.iso && !(suffix && suffix.iso)) {
        const lead = findIsoBefore(text, prefix.start);
        if (lead) { key = lead.code; startIdx = lead.start; }
      }
      let code = key;
      if (String(key).startsWith("AMB_")) {
        const near = text.slice(Math.max(0, startIdx - 24), Math.min(text.length, endIdx + 24));
        code = resolveAmbiguous(key, ctx, wordForm, /[぀-ヿ]/.test(near));
        if (!code) { skipped.push({ start: startIdx, end: endIdx, reason: "currency-ambiguous" }); i = Math.max(endIdx, i + 1); continue; }
      }
      if (code === "KRW" || !FIAT.has(code)) { i = Math.max(endIdx, i + 1); continue; }
      const per = krwPer ? krwPer[code] : undefined;
      // 이미 원화 주석이 붙어 있거나 범위 표기의 앞쪽이면 건너뛴다(중복·어색한 삽입 방지).
      const after = text.slice(endIdx, endIdx + 28);
      if (KRW_AFTER.test(after)) { i = Math.max(endIdx, i + 1); continue; }
      if (RANGE_AFTER.test(after)) { skipped.push({ start: startIdx, end: endIdx, reason: "range" }); i = Math.max(endIdx, i + 1); continue; }
      if (typeof per === "number" && isFinite(per) && per > 0) {
        const krw = number.value * per;
        const label = formatKRW(krw);
        if (label) mentions.push({ start: startIdx, end: endIdx, code, amount: number.value, krw, text: label });
      } else {
        mentions.push({ start: startIdx, end: endIdx, code, amount: number.value, krw: null, text: null });
      }
      i = Math.max(endIdx, i + 1);
    }
    return { mentions, skipped };
  }

  function scanEndOf(text, i) {
    let p = i;
    while (p < text.length && (isDigit(text[p]) || ((text[p] === "," || text[p] === "." || text[p] === "'" || text[p] === "’" || isSpaceChar(text[p])) && isDigit(text[p + 1])))) p += 1;
    return p;
  }

  function findIsoBefore(text, start) {
    let e = start;
    if (e > 0 && isSpaceChar(text[e - 1])) e -= 1;
    if (e < 3) return null;
    const code = text.slice(e - 3, e);
    if (/^[A-Z]{3}$/.test(code) && FIAT.has(code) && boundaryBefore(text, e - 3)) return { start: e - 3, code };
    return null;
  }

  /** 원화 표시 문자열("약 138,600원"). 너무 작은 값은 null. */
  function formatKRW(value) {
    if (!(value > 0) || !isFinite(value)) return null;
    let n;
    if (value >= 100) n = Math.round(value).toLocaleString("en-US");
    else if (value >= 1) n = (Math.round(value * 10) / 10).toLocaleString("en-US", { maximumFractionDigits: 1 });
    else if (value >= 0.01) n = (Math.round(value * 100) / 100).toLocaleString("en-US", { maximumFractionDigits: 2 });
    else return null;
    return `약 ${n}원`;
  }

  // MARK: 환율 정규화·검증

  function normalizeRates(raw) {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
    const rates = {};
    let count = 0;
    for (const [name, value] of Object.entries(raw)) {
      const code = String(name).toUpperCase();
      if (!/^[A-Z]{3}$/.test(code) || !FIAT.has(code)) continue;
      if (typeof value !== "number" || !isFinite(value) || value <= 0) continue;
      rates[code] = value;
      count += 1;
    }
    if (!rates.USD) rates.USD = 1;
    if (!(rates.KRW > 0) || count < 5) return null;
    return rates;
  }

  /** 교차 환산: 금액 × KRW / 통화 (USD=1). 1통화 단위당 원화 표. */
  function krwTable(rates) {
    const table = {};
    if (!rates || !(rates.KRW > 0)) return table;
    for (const [code, rate] of Object.entries(rates)) {
      if (!(rate > 0)) continue;
      const per = rates.KRW / rate;
      if (isFinite(per) && per > 0) table[code] = per;
    }
    return table;
  }

  function parseTime(value) {
    if (value === undefined || value === null || value === "") return null;
    if (typeof value === "number" && isFinite(value)) return value < 1e12 ? value * 1000 : value;
    if (typeof value === "string") {
      if (/^\d+(\.\d+)?$/.test(value.trim())) { const n = Number(value); return n < 1e12 ? n * 1000 : n; }
      const t = Date.parse(value);
      return isFinite(t) ? t : null;
    }
    return null;
  }

  function parsePrimary(json) {
    if (!json || json.result !== "success" || String(json.base || "").toUpperCase() !== "USD") return null;
    const rates = normalizeRates(json.rates);
    if (!rates) return null;
    // 제공사가 알려준 '관측 시각'. 우리가 받아 온 시각(fetchedAt)과 따로 둔다.
    const sourceTs = parseTime(json.data_updated_at) ?? parseTime(json.effective_at) ?? parseTime(json.timestamp);
    // 유효한 제공사 관측 시각이 필수(수신 시각으로 대체하지 않음). 24시간 넘는 미래도 거부.
    if (sourceTs === null || sourceTs > Date.now() + 86400000) return null;
    return { provider: "exchangerate.dev", rates, sourceTs, sourceDate: sourceTs !== null ? new Date(sourceTs).toISOString() : null,
             stale: json.stale === true, delayed: true };
  }

  function parseFawaz(json, url) {
    if (!json || typeof json.date !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(json.date)) return null;
    const rates = normalizeRates(json.usd);
    if (!rates) return null;
    // 실제 달력 날짜 + 문자열 왕복 일치 + 24시간 넘는 미래 거부
    const dateTs = Date.parse(`${json.date}T00:00:00Z`);
    if (!isFinite(dateTs) || new Date(dateTs).toISOString().slice(0, 10) !== json.date || dateTs > Date.now() + 86400000) return null;
    return { provider: "fawazahmed0", rates, sourceTs: dateTs, sourceDate: json.date, stale: false,
             delayed: false, host: (() => { try { return new URL(url).host; } catch { return ""; } })() };
  }

  function kst(ts) {
    try {
      return new Intl.DateTimeFormat("ko-KR", { year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hour12: false })
        .format(new Date(ts)).replace(/\.\s*/g, "-").replace(/-\s?(\d\d):/, " $1:").replace(/-$/, "");
    } catch { return new Date(ts).toISOString().slice(0, 16).replace("T", " "); }
  }

  /** 팝업·상태 줄 문구. meta가 없으면 안내 문구. */
  function statusLine(meta) {
    if (!meta) return NO_RATE_MESSAGE;
    if (meta.mixed) return `${meta.saved ? "저장 환율 · " : ""}혼합 출처 · 주 기준 ${kst(meta.sourceTs)} · 일부 통화 일별 ${String(meta.dailyDate).slice(0, 10)} · 참고용`;
    const date = meta.provider === "fawazahmed0" || meta.sourceTs === null
      ? (meta.sourceDate ? String(meta.sourceDate).slice(0, 10) : "기준일 미상")
      : kst(meta.sourceTs);
    const name = meta.provider === "exchangerate.dev" ? "" : "Fawaz 일별 환율 ";
    const delay = meta.provider === "exchangerate.dev" ? " · 약 15분 지연" : " · 일 단위";
    return `${meta.saved ? "저장 환율 · " : ""}${name}기준 ${date}${delay} · 참고용`;
  }

  function statusDetail(meta) {
    if (!meta) return NO_RATE_MESSAGE;
    if (meta.mixed) {
      return `혼합 출처: Exchangerate.dev(약 15분 지연) 기준 ${meta.sourceTs !== null ? kst(meta.sourceTs) : "미상"} + 주 응답에 없는 통화는 Fawaz 일별 ${String(meta.dailyDate).slice(0, 10)}` +
        `(그 일별 자료 자체의 KRW로 환산) · 받은 시각 ${kst(meta.fetchedAt)}(제공사 시각과 다름)${meta.saved ? " · 저장 환율" : ""} · 참고용, 실시간 아님`;
    }
    const provider = meta.provider === "exchangerate.dev" ? "Exchangerate.dev(키 없는 무료 데이터, 약 15분 지연)" : "Fawaz Ahmed 통화 API(일별)";
    const fetched = meta.fetchedAt ? `받은 시각 ${kst(meta.fetchedAt)}` : "";
    return `${provider} · 제공사 기준 ${meta.provider === "fawazahmed0" ? String(meta.sourceDate || "").slice(0, 10) : (meta.sourceTs !== null ? kst(meta.sourceTs) : "미상")}` +
      `${fetched ? ` · ${fetched}(제공사 시각과 다름)` : ""}${meta.saved ? " · 저장 환율" : ""}${meta.stale ? " · 제공사 표시: 지연" : ""} · 참고용, 실시간 아님`;
  }

  // MARK: 저장소(배경 전용)

  function createStore(api) {
    const storage = api && api.storage && api.storage.local;
    let primary = null; // exchangerate.dev 응답 { provider, rates, sourceTs, sourceDate, stale, delayed, fetchedAt }
    let daily = null; // fawazahmed0 일별 응답(보조) — 주 응답에 없는 통화에만 쓰며 환산은 이 응답 자신의 KRW로 한다
    let table = {};
    let extraCodes = 0; // 일별 보조에서 가져온 통화 수
    let attempt = null; // { at, ok, code }
    let loaded = null;
    let inflight = null;
    const listeners = new Set();

    function validStored(value) {
      if (!value || typeof value !== "object" || (value.provider !== "exchangerate.dev" && value.provider !== "fawazahmed0")) return null;
      const rates = normalizeRates(value.rates);
      if (!rates || !Number.isFinite(value.fetchedAt)) return null;
      return { provider: value.provider, rates, sourceTs: Number.isFinite(value.sourceTs) ? value.sourceTs : null,
               sourceDate: typeof value.sourceDate === "string" ? value.sourceDate : null, stale: value.stale === true,
               delayed: value.provider === "exchangerate.dev", fetchedAt: value.fetchedAt, host: typeof value.host === "string" ? value.host : "" };
    }

    /** 주 응답 표 + 주 응답에 없는 통화만 일별 표(각자 자신의 KRW 기준). */
    function rebuild() {
      table = primary ? krwTable(primary.rates) : {};
      extraCodes = 0;
      if (daily) {
        const own = krwTable(daily.rates);
        for (const [code, per] of Object.entries(own)) {
          if (table[code] === undefined) { table[code] = per; if (primary) extraCodes += 1; }
        }
      }
    }

    function load() {
      if (!loaded) {
        loaded = Promise.resolve().then(() => (storage ? storage.get([CACHE_KEY, DAILY_KEY, ATTEMPT_KEY]) : {})).then((stored) => {
          const first = validStored(stored[CACHE_KEY]);
          const second = validStored(stored[DAILY_KEY]);
          // 이전 버전은 일별 응답을 주 슬롯에 저장했다: 제공사별 슬롯으로 옮겨 읽는다.
          primary = first && first.provider === "exchangerate.dev" ? first : null;
          daily = second && second.provider === "fawazahmed0" ? second : (first && first.provider === "fawazahmed0" ? first : null);
          rebuild();
          const a = stored[ATTEMPT_KEY];
          attempt = a && Number.isFinite(a.at) ? { at: a.at, ok: a.ok === true, code: typeof a.code === "string" ? a.code : "" } : null;
        }).catch(() => {});
      }
      return loaded;
    }

    function snapshot() {
      const shown = primary || daily;
      if (!shown) return { ok: true, has: false, krwPer: {}, meta: null, message: NO_RATE_MESSAGE };
      const now = Date.now();
      const saved = (attempt && !attempt.ok) || now - shown.fetchedAt > SAVED_AFTER;
      const mixed = !!primary && extraCodes > 0;
      const meta = { provider: shown.provider, sourceTs: shown.sourceTs, sourceDate: shown.sourceDate, fetchedAt: shown.fetchedAt,
                     stale: shown.stale, delayed: shown.delayed, saved, attribution: !!primary, mixed,
                     dailyDate: mixed ? daily.sourceDate : null };
      return { ok: true, has: true, krwPer: table, meta, text: statusLine(meta), detail: statusDetail(meta),
               attribution: meta.attribution ? { text: ATTRIBUTION_TEXT, url: ATTRIBUTION_URL } : null };
    }

    async function getJson(url) {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), ENDPOINT_TIMEOUT);
      try {
        const response = await fetch(url, { method: "GET", credentials: "omit", cache: "no-store", referrerPolicy: "no-referrer",
                                            redirect: "follow", signal: controller.signal });
        if (!response.ok) { const e = new Error(`http ${response.status}`); e.retry = response.status >= 500; throw e; }
        const body = await response.text();
        if (body.length > MAX_BODY) throw new Error("too large");
        return JSON.parse(body);
      } finally {
        clearTimeout(timer);
      }
    }

    async function tryEndpoint(url, parse, tries) {
      let lastError = null;
      for (let n = 0; n < tries; n += 1) {
        try {
          const parsed = parse(await getJson(url), url);
          if (parsed) return parsed;
          lastError = new Error("invalid");
          break; // 형식이 틀린 응답은 다시 받아도 같다
        } catch (error) {
          lastError = error;
          if (error && error.retry === false) break;
          if (n + 1 < tries) await new Promise((resolve) => setTimeout(resolve, 700));
        }
      }
      throw lastError || new Error("failed");
    }

    /** 엔드포인트 목록을 차례로 시도해 처음 유효한 응답을 돌려준다. { result, code } */
    async function firstValid(endpoints) {
      let code = "failed";
      for (const [url, parse, tries] of endpoints) {
        try { return { result: await tryEndpoint(url, parse, tries), code: "" }; } catch (error) {
          code = error && error.name === "AbortError" ? "timeout" : (error && error.message === "invalid" ? "invalid" : "network");
        }
      }
      return { result: null, code };
    }

    async function run() {
      const startedAt = Date.now();
      attempt = { at: startedAt, ok: false, code: "pending" };
      // 주 응답이 성공해도 일별 보조 스냅샷을 함께 받는다(주 응답에 없는 통화용). 노드마다 요청하지 않고 이 한 번뿐이다.
      const [p, d] = await Promise.all([
        firstValid([[PRIMARY_URL, parsePrimary, 2]]),
        firstValid(FALLBACK_URLS.map((u) => [u, parseFawaz, 1]))
      ]);
      const writes = {};
      // 더 오래된 응답으로 이미 저장된 더 새로운 값을 덮어쓰지 않는다.
      if (p.result && !(primary && primary.sourceTs !== null && p.result.sourceTs !== null && p.result.sourceTs < primary.sourceTs)) {
        primary = { ...p.result, fetchedAt: Date.now() };
        writes[CACHE_KEY] = primary;
      }
      if (d.result && !(daily && daily.sourceDate && d.result.sourceDate < daily.sourceDate)) {
        daily = { ...d.result, fetchedAt: Date.now() };
        writes[DAILY_KEY] = daily;
      }
      const ok = !!p.result || (!primary && !!d.result);
      attempt = { at: startedAt, ok, code: ok ? "" : (p.code || d.code || "failed") };
      writes[ATTEMPT_KEY] = attempt;
      const changed = Object.keys(writes).length > 1;
      if (changed) rebuild();
      try { await storage.set(writes); } catch {}
      if (changed) for (const listener of listeners) { try { listener(snapshot()); } catch {} }
    }

    /** 환율 갱신을 시작한다(기다리지 않아도 된다). 같은 시각 겹치는 요청은 하나로 합친다. */
    async function refresh(reason, force) {
      await load();
      if (typeof navigator !== "undefined" && navigator.onLine === false) return snapshot();
      if (inflight) return inflight.then(snapshot, snapshot);
      const now = Date.now();
      if (!force && attempt && attempt.code !== "pending") {
        const gap = primary || daily ? REFRESH_INTERVAL : NO_CACHE_RETRY;
        if (now - attempt.at < gap) return snapshot();
      }
      inflight = run().finally(() => { inflight = null; });
      return inflight.then(snapshot, snapshot);
    }

    return {
      /** 저장된 환율을 바로 돌려주고(기다리지 않음) 필요하면 뒤에서 갱신한다. */
      async get(reason) {
        await load();
        refresh(reason || "get", false).catch(() => {});
        return snapshot();
      },
      refresh,
      snapshot: async () => { await load(); return snapshot(); },
      onUpdate(listener) { listeners.add(listener); return () => listeners.delete(listener); }
    };
  }

  globalThis.BarobogiFX = Object.freeze({
    FIAT, PRIMARY_URL, FALLBACK_URLS, ATTRIBUTION_TEXT, ATTRIBUTION_URL, NO_RATE_MESSAGE,
    makeContext, findAmounts, formatKRW, krwTable, normalizeRates, parsePrimary, parseFawaz, statusLine, statusDetail, createStore
  });
})();
