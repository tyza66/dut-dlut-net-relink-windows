document.body.onload = a;

function a() {
    try {
        if (window.localStorage) {
            //重新登录的时候清除掉localStorage
            window.localStorage.clear();
        }
        if (window.sessionStorage) {
            //重新登录的时候清除掉sessionStorage
            window.sessionStorage.clear();
        }
    } catch (e) {
    }


    let setting = {
        imageWidth: 1680,
        imageHeight: 1050

    };
    $("#index_login_btn").click(function () {
        login();
    });

    $(document).keydown(function (event) {
        if (event.keyCode == 13) {
            login();
        }
    });
    let init = function () {
        let windowHeight = $(window).height();

        let windowWidth = $(window).width();
        $(".login_conatiner").css("height", windowHeight);
        $(".login_conatiner").css("width", windowWidth);

        $("#container_bg").css("height", windowHeight);
        $("#container_bg").css("width", windowWidth);

        $("#login_right_box").css("height", windowHeight);

        var imgW = setting.imageWidth;
        var imgH = setting.imageHeight;
        var ratio = imgH / imgW; // 图片的高宽比

        imgW = windowWidth; // 图片的宽度等于窗口宽度
        imgH = Math.round(windowWidth * ratio); // 图片高度等于图片宽度 乘以 高宽比

        if (imgH < windowHeight) { // 但如果图片高度小于窗口高度的话
            imgH = windowHeight; // 让图片高度等于窗口高度
            imgW = Math.round(imgH / ratio); // 图片宽度等于图片高度 除以 高宽比
        }

        $(".login_img_01").width(imgW).height(imgH); // 设置图片高度和宽度
    };

    init();

    $(window).resize(function () {
        init();
    });

    //如果有错误信息，则显示
    if ($("#errormsghide").text()) {
        $("#errormsg").text($("#errormsghide").text()).show();
    }
}


function login() {
    $("#loginForm")[0].submit();
}

function getParameter(hash, name, nvl) {
    if (!nvl) {
        nvl = "";
    }
    var svalue = hash.match(new RegExp("[\?\&]?" + name + "=([^\&\#]*)(\&?)", "i"));
    if (svalue == null) {
        return nvl;
    } else {
        svalue = svalue ? svalue[1] : svalue;
        svalue = svalue.replace(/<script>/gi, "").replace(/<\/script>/gi, "").replace(/<html>/gi, "").replace(/<\/html>/gi, "").replace(/alert/gi, "").replace(/<span>/gi, "").replace(/<\/span>/gi, "").replace(/<div>/gi, "").replace(/<\/div>/gi, "");
        return svalue;
    }
}