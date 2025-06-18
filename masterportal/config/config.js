const Config = {
  addons: ["embedit"],
  ignoredKeys: ["BOUNDEDBY", "SHAPE", "SHAPE_LENGTH", "SHAPE_AREA", "OBJECTID", "OBJECTID_1", "GLOBALID", "GEOMETRY", "SHP", "SHP_AREA", "SHP_LENGTH", "GEOM", "O_CODE", "O_KAT", "O_FKT"],
  mapMarker: {
    pointStyleId: "customMapMarker",
  },
  wfsImgPath: "./resources/img/",
  allowParametricURL: false,
  wfsImgPath: "./resources/img/",
  namedProjections: [
    // GK DHDN
    ["EPSG:31467", "+title=Bessel/Gauß-Krüger 3 +proj=tmerc +lat_0=0 +lon_0=9 +k=1 +x_0=3500000 +y_0=0 +ellps=bessel +datum=potsdam +units=m +no_defs"],
    // ETRS89 UTM
    ["EPSG:25832", "+title=ETRS89/UTM 32N +proj=utm +zone=32 +ellps=GRS80 +towgs84=0,0,0,0,0,0,0 +units=m +no_defs"],

    // WGS84
    ["EPSG:4326", "+title=WGS 84 (long/lat) +proj=longlat +ellps=WGS84 +datum=WGS84 +no_defs"]
  ],
  quickHelp: {
    imgPath: "./resources/img/"
  },
  portalConf: "./config.json",
  layerConf: "./resources/services-internet.json",
  restConf: "./resources/rest-services-internet.json",
  styleConf: "./resources/style_v3.json",
  attributions: true,
  mouseHover: {
    numFeaturesToShow: 2,
    infoText: "(weitere Objekte. Bitte zoomen.)"
  },
  obliqueMap: true,
  portalLanguage: {
    enabled: false,
    debug: false,
    languages: {
      de: "Deutsch",
      en: "English",
    },
    fallbackLanguage: "de",
    changeLanguageOnStartWhen: ["querystring", "localStorage", "htmlTag"]
  }
};

// conditional export to make config readable by e2e tests
if (typeof module !== "undefined") {
  module.exports = Config;
};
