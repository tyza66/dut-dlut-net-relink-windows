let confirmId;

//国际化语言,中文为cn，英文为en
var lang = 'cn';
var fqrcode = ""
$("#errormsg").hide();

$(function() {
	// $('#camera_wrap_4').slick({
	// 	autoplay: true, // 自动播放
	// 	autoplaySpeed: 5000, // 自动播放间隔时间
	// 	arrows: false, // 显示箭头导航
	// 	dots: false, // 显示圆点导航
	// 	infinite: true, // 无限循环
	// 	speed: 2000, // 滑动速度
	// 	slidesToShow: 1, // 同时显示的幻灯片数量
	// 	slidesToScroll: 1, // 每次滑动的幻灯片数量
	// 	draggable:false,//禁止拖拽
	// 	//fade: true,//添加淡出效果
	// 	pauseOnHover: false,
	// 	pauseOnFocus:false,
	// 	pauseOnHover:false,
	// 	swipeToSlide:false,
	// 	lazyLoad:'progressive',
	// 	dots: true
	// });x

	document.cookie = "cas_hash=" + encodeURIComponent(window.location.hash) ;
	try{
		if(window.localStorage){
			//重新登录的时候清除掉localStorage
			window.localStorage.clear();
		}
		if(window.sessionStorage){
			//重新登录的时候清除掉sessionStorage
			window.sessionStorage.clear();
		}
	}catch(e){}
	//判断service地址，如果是门户平台则直接改为https协议
	replaceHash(GetQueryString("service"));

	// 新的扫码模块
	var lqrcode = new loginQRCode("qrcode",143,143);
	lqrcode.generateLoginQRCode(function(result){
		window.location.href = result.redirect_url;
	});

	var mobileErrorText;

	//密码找回的中英文切换
	if($("#change_language").attr("value") == "中文"){
		$("#pwd_url").attr("href",$("#pwd_url").attr("href")+"?locale=en");
		lang = "en";
	}else{
		$("#pwd_url").attr("href",$("#pwd_url").attr("href")+"?locale=zh_CN");
		lang = "cn";
	}

	//点击账号登录
	$("#password_login").unbind("click").bind("click",function(){
		if(fqrcode) fqrcode.clear();
		$("#password_login_content").show();
		$("#mobile_login_content").hide();
		$("#face_login_content").hide();
		$("#remember_retrieve").show();
		$("#password_login").addClass("active");
		$("#face_login").removeClass("active");
		$("#mobile_login").removeClass("active");
		$("#errormsg").hide();
		$("#loginSubmitBtn").show();
	});

	$('a[name="a_eye"]').click(function(){
		if($(this).hasClass("eye-close")){
			$(this).removeClass("eye-close");
			$(this).addClass("eye-open");
			$(this).prev().attr("type" , "input");
		}else{
			$(this).removeClass("eye-open");
			$(this).addClass("eye-close");
			$(this).prev().attr("type" , "password");
		}
	})

	//点击手机登录
	$("#mobile_login").unbind("click").bind("click",function(){
		if(fqrcode) fqrcode.clear();
		$("#password_login_content").hide();
		$("#face_login_content").hide();
		$("#mobile_login_content").show();
		$("#remember_retrieve").hide();
		$("#face_login").removeClass("active");
		$("#password_login").removeClass("active");
		$("#mobile_login").addClass("active");
		$("#loginSubmitBtn").show();
		initErrormsg();
		//重新获取验证码
		$("#a_changeCode_mobile").unbind("click").bind("click",function(){
			$("#codeImage_mobile").attr("src", "code?"+Math.random()) ;
		});
		$("#errormsg").hide();
	});
	//点击人脸识别登录
	$("#face_login").unbind("click").bind("click",function(){
		$("#password_login_content").hide();
		$("#mobile_login_content").hide();
		$("#face_login_content").show();
		$("#remember_retrieve").hide();
		$("#password_login").removeClass("active");
		$("#mobile_login").removeClass("active");
		$("#face_login").addClass("active");
		$("#loginSubmitBtn").hide();
		$("#errormsg").hide();
		// 新的扫码模块
		if(fqrcode) fqrcode.clear();
		fqrcode= new faceLoginQRCode("faceQrCode",125,125);
		fqrcode.generateLoginQRCode(function(result){
			window.location.href = result.redirect_url;
		});
	});
	//点击人脸识别登录
	$("#a_fqrcode").click(function(){
		$("#div_qrcode").hide();
		$("#div_appqrcode").hide();
		$("#div_fqrcode").show();
		$("#div_qr_title").text("微信人脸登录");

		if(fqrcode) fqrcode.clear();
		fqrcode= new faceLoginQRCode("faceQrCode",125,125);
		fqrcode.generateLoginQRCode(function(result){
			window.location.href = result.redirect_url;
		});
		
	});

	//刷新app二维码
	$("#btn_appqrcode_fresh").click(function(){
		$("#appQrCode").empty();
		var qrcode = new QRCode(document.getElementById("appQrCode"), {
		    width: 155,
		    height: 155,
		});
		var uuid = generateUUID();
		$.get("cb?method=getQrCode&uuid="+uuid , function(data){
			qrcode.makeCode(data.code);
			fresh(uuid);
			$("#div_appqrcode_timeout").hide();
		})
	});

	//点击app人脸识别登录
	$("#a_aqrcode").click(function(){
		$("#div_qrcode").hide();
		$("#div_fqrcode").hide();
		$("#div_appqrcode").show();
		$("#div_qr_title").text("国家网证扫码登录");

		$("#appQrCode").empty();
		var qrcode = new QRCode(document.getElementById("appQrCode"), {
		    width: 155,
		    height: 155,
		});
		var uuid = generateUUID();
		$.get("cb?method=getQrCode&uuid="+uuid , function(data){
			qrcode.makeCode(data.code);
			fresh(uuid);
		})
		
	});


	//点击微信登录
	$("#a_qrcode").click(function(){
		$("#div_fqrcode").hide();
		$("#div_appqrcode").hide();
		$("#div_qrcode").show();
		$("#div_qr_title").text("微信扫码登录");
	});

	$("#change_language").unbind("click").click(function(){
		var re=eval('/(locale=)([^&]*)/gi');
		var url = window.location.href;

		if($("#change_language").attr("value") == "中文"){
			if(url.indexOf("locale") >= 0 ) {
				url=url.replace(re,'locale=zh_CN');
				location.href=url;
			}else{
				if(url.indexOf("?") >= 0){
					location.href=url+"&locale=zh_CN";
				}else{
					location.href=url+"?locale=zh_CN";
				}
			}
		}else if($("#change_language").attr("value") == "English") {
			if(url.indexOf("locale") >= 0 ) {
				url=url.replace(re,'locale=en');
				location.href=url;
			}else{
				if(url.indexOf("?") >= 0){
					location.href=url+"&locale=en";
				}else{
					location.href=url+"?locale=en";
				}
			}
		}
	});

	initContainerEvent();

	//建议浏览器
	$("#ie_blank").click(function(){
		window.open("http://windows.microsoft.com/zh-cn/internet-explorer/download-ie");
	});
	$("#firefox_blank").click(function(){
		window.open("http://www.firefox.com.cn/download/");
	});
	$("#chrome_blank").click(function(){
		window.open("https://www.google.cn/intl/zh-CN/chrome/");
	});
});

function initContainerEvent() {
	//点击记住用户名
	$("#rememberName").change(function(){
		if($(this).is(":checked")){
			let $u = $("#un").val() ;
			if($.trim($u)==''){
				$("#errormsg").text("账号不能为空").show();
//				$(this).removeAttr("checked");
				$(this).prop("checked", false);
			}else{
				//不等于空，写cookie
				$.cookie('dlut_cas_un' , $u , { expires: 365});
				document.getElementById('pd').focus()
			}
		}else{
			//反选之后清空cookie
			$.removeCookie('dlut_cas_un');
		}
	});

	//点击记住手机号
	$("#rememberPhone").change(function(){
		if($(this).is(":checked")){
			let $phone = $("#phone").val() ;
			if($.trim($phone)==''){
				$("#errormsg").text("手机号不能为空").show();
				$(this).prop("checked", false);
			}else{
				//不等于空，写cookie
				$.cookie('dlut_cas_phone' , $phone , { expires: 365});
				document.getElementById('code').focus()
			}
		}else{
			//反选之后清空cookie
			$.removeCookie('dlut_cas_phone');
		}
	});


	//登录按钮触发
	$("#index_login_btn").unbind("click").bind("click",function(){
		//判断是账号密码登录还是短信验证码登录
		if($("#mobile_login").hasClass("active")){
			//手机验证码登录
			loginBtn();
		}else{
			//账号密码登录
			login();
		}
	});

	//用户名文本域keyup事件
	$("#un").keyup(function(e){
		if(e.which == 13) {
			login();
		}
	}).keydown(function(e){
		$("#errormsg").hide();
	}).focus();

	//密码文本域keyup事件
	$("#pd").keyup(function(e){
		if($(this).val()==''){
			$('a[name="a_eye"]').hide();
		}else{
			$('a[name="a_eye"]').show();
		}
		if(e.which == 13) {
			login();
		}
	}).keydown(function(e){
		$("#errormsg").hide();
	});

	//如果有错误信息，则显示
	if($("#errormsghide").text()){
		$("#errormsg").text($("#errormsghide").text()).show();
		mobileErrorText = $("#errormsghide").text();
	}

	//重新获取验证码
	$("#a_changeCode").unbind("click").bind("click",function(){
		$("#codeImage").attr("src", "code?"+Math.random()) ;
	});
	$("#a_changeCode_mobile").unbind("click").bind("click",function(){
		$("#codeImage_mobile").attr("src", "code?"+Math.random()) ;
	});

	//获取cookie值
	let cookie = $.cookie('dlut_cas_un');
	if(cookie){
		$("#un").val(cookie);
		$("#rememberName").attr("checked","checked");
	}

	//获取cookie值
	let cookiePhone = $.cookie('dlut_cas_phone');
	if(cookiePhone){
		$("#phone").val(cookiePhone);
		$("#rememberPhone").attr("checked","checked");
	}


	var ifchecked = function(){
		if($("#rememberName").is(":checked")){
			document.getElementById('pd').focus()
		}
	};
	ifchecked();
}

function initErrormsg(){
	testTTT();
	$("#phone").keyup(function(e){
		if(e.which == 11){
			loginBtn();
		}
	}).keydown(function(e){
		$("#errormsg").hide();
	}).focus();


	$("#phoneCode").keyup(function(e){
		if(e.which == 10){
			loginBtn();
		}
	}).keydown(function(e){
		$("#errormsg").hide();
	});
}
function testTTT(){
	$('#getPhone').click(function () {
		
		var phone = $("#phone").val().trim();
		var code = $("#code").val().trim();
		if(phone === ""){
			$("#phone").focus();
			$("#errormsg").text("手机号不能为空").show();
			return ;
		}
		if(code === ""){
			$("#code").focus();
			$("#errormsg").text("图形验证码不能为空").show();
			return ;
		}
		var mreg = /^0?1\d{10}$/;

		if(!mreg.test(phone)){
			$("#phone").focus();
			$("#phone").parent().addClass("login_error_border");
			$("#errormsg").text("手机号格式有误").show();
			return ;
		}
		if($(this).attr("disabled") == 'disabled'){
			return ;
		}
		LockButton("#getPhone", 120);
		$(this).attr("disabled", "disabled");
//		$("#getPhoneCode").attr("src", "mobilecode?phone=" + phone + "&code=" + code + "&method=isPhone&" + Math.random());
		$.get("mobilecode?phone=" + phone + "&code=" + code + "&method=isPhone&" + Math.random() , function(){
			$("#codeImage_mobile").trigger("click");
		});
	})

	if($.cookie("djsendtime") != undefined && !isNaN($.cookie("djsendtime"))){
		var djsendtime = $.cookie("djsendtime");
		var now = new Date().getTime();
		var lockseconds = parseInt((djsendtime - now) / 1000);
		if(lockseconds <= 0){
			$.cookie("djsendtime", null);
		}else{
			LockButton('#getPhone', lockseconds);
		}
	}
}

var LockButton = function(btnObjId, lockseconds){
	var errorInfo = true;
	var djsendtime = $.cookie("djsendtime");
	if(djsendtime == undefined || djsendtime == 'undefined' || djsendtime == null || djsendtime == 'null'){
		var now = new Date().getTime();
		var end = lockseconds * 1000 + now;
		$.cookie("djsendtime", end);
	}
	document.getElementById('getPhone').style.color = "#808080";
	if(lang=="cn"){
		document.getElementById('getPhone').innerHTML = '(' + lockseconds + ')后重新获取';
	}else{
		document.getElementById('getPhone').innerHTML = 'Get again in (' + lockseconds + ') seconds';
	}
	var timer = setInterval(function(){
		lockseconds--;
		if(lang=="cn"){
			document.getElementById('getPhone').innerHTML = '(' + lockseconds + ')后重新获取';
		}else{
			document.getElementById('getPhone').innerHTML = 'Get again in (' + lockseconds + ') seconds';
		}
		if (lockseconds <= 0) {
			$.removeCookie("djsendtime");
			$("#getPhone").removeAttr("disabled");
			document.getElementById('getPhone').style.color="#008838";
			if(lang=="cn"){
				document.getElementById('getPhone').innerHTML = "重新获取";
			}else{
				document.getElementById('getPhone').innerHTML = "Get again";
			}
			clearInterval(timer);
		}
		if(errorInfo){
			var isResetImg = false;
			var error_mobile_info = $.cookie("mobile_error_info");
			
			if(error_mobile_info != null && error_mobile_info != undefined && error_mobile_info != 'undefined' && error_mobile_info != 'null' && "user_not_exist" == error_mobile_info){
				//该学工号未绑定手机号，请使用账号与微信扫码登录，进入“我的信息”---“安全设置“绑定手机号
				//该手机号未被绑定,请用账号登录后在”我的信息——安全设置“中绑定手机号!
				$("#errormsg").text(lang=='cn'?"该手机号未被绑定":'The phone number is not bound.');
				$("#errormsg").show();
				isResetImg = true;
				errorInfo = false;
				$.cookie("mobile_error_info", null);
				lockseconds = 0;
				$.removeCookie("djsendtime");
			}else if(error_mobile_info != null && error_mobile_info != undefined && error_mobile_info != 'undefined' && error_mobile_info != 'null' && "error1" == error_mobile_info){
				//您的验证码获取太频繁，请于10分钟之后重试
				$("#errormsg").text(lang=='cn'?"\u60a8\u7684\u9a8c\u8bc1\u7801\u83b7\u53d6\u592a\u9891\u7e41\uff0c\u8bf7\u4e8e\u0031\u0030\u5206\u949f\u4e4b\u540e\u91cd\u8bd5":"Your verification code has been asked too frequently. Please try again 10 minutes later");
				$("#errormsg").show();
				isResetImg = true;
				errorInfo = false;
				$.cookie("mobile_error_info", null);
			}else if(error_mobile_info != null && error_mobile_info != undefined && error_mobile_info != 'undefined' && error_mobile_info != 'null' && "error2" == error_mobile_info){
				//一天只能发送100次验证码
				$("#errormsg").text(lang=='cn'?"\u4e00\u5929\u53ea\u80fd\u53d1\u9001\u0031\u0030\u0030\u6b21\u9a8c\u8bc1\u7801":"Only 100 verification codes can be sent per day");
				$("#errormsg").show();
				isResetImg = true;
				errorInfo = false;
				$.cookie("mobile_error_info", null);
			}else if(error_mobile_info != null && error_mobile_info != undefined && error_mobile_info != 'undefined' && error_mobile_info != 'null' && "success" == error_mobile_info){
				//验证码已发送，请注意查收
				$("#errormsg").text(lang=='cn'?"\u9a8c\u8bc1\u7801\u5df2\u53d1\u9001\uff0c\u8bf7\u6ce8\u610f\u67e5\u6536":"The verification code has been sent; please check it");
				$("#errormsg").show();
				errorInfo=false;
				$.cookie("mobile_error_info", null);
			}else if(error_mobile_info != null && error_mobile_info != undefined && error_mobile_info != 'undefined' && error_mobile_info != 'null' && "img_code_error" == error_mobile_info){
				//图形验证码错误，请重新输入
				$("#errormsg").text(lang=='cn'?"\u56fe\u5f62\u9a8c\u8bc1\u7801\u9519\u8bef\uff0c\u8bf7\u91cd\u65b0\u8f93\u5165":"Incorrect graphic verification code; please re-enter");
				$("#errormsg").show();
				errorInfo = false;
				lockseconds = 0;
				$.cookie("mobile_error_info", null);
				// 重置图形验证码
				//$("#codeImage_mobile").trigger("click");
			}else if(error_mobile_info != null && error_mobile_info != undefined && error_mobile_info != 'undefined' && error_mobile_info != 'null' && "mobile_reg_error" == error_mobile_info){
				//手机号格式错误，请重新输入
				$("#errormsg").text(lang=='cn'?"\u624b\u673a\u53f7\u683c\u5f0f\u9519\u8bef\uff0c\u8bf7\u91cd\u65b0\u8f93\u5165":"Incorrect phone number format; please re-enter");
				$("#errormsg").show();
				isResetImg = true;
				errorInfo = false;
				lockseconds = 0;
				$.cookie("mobile_error_info", null);
			}
			// if (isResetImg) {
			// if (isResetImg) {
				//只要有错误就重置图片验证码
			// }
		}
	}, 1000);
};

// 弹窗提示用户选择登陆账号（手机登录对应多账号的情况）
function chooseMobileAccount(data) {
	var choose_content = "";
	for (var i = 0; i < data.length; i++) {
		choose_content += "<li class=\"popup-select-item\" name='choose_user'><div class='user-number' name='id_number'>"+data[i].ID_NUMBER+"</div><div className=\"user-name\">"+data[i].USER_NAME+"</div></li>";
	}
	//id为accountContent的标签下添加choose_content
	$("#accountContent").html(choose_content);
	$("#choose_id").show();
	$("#choose_close").click(function(){
		// 关闭选择账号的open弹出框
		$("#accountContent").html("");
		$("#choose_id").hide();
	})

	$("li[name='choose_user']").click(function(){
		var idnumber = $(this).find("div[name='id_number']").text();
		if(lang=='cn'){
			layer.confirm('确认登录账号[' + idnumber + ']？', {
				title:"登录确认",
				time: 0 //不自动关闭
				,btn: ['确认', '取消']
				,yes: function(index){
					layer.close(index);
					confirmId = idnumber;
					// 关闭选择账号的open弹出框
					$("#accountContent").html("");
					$("#choose_id").hide();
					// 执行登录流程
					loginBtnTrue();
				}
			});
			
		}else{
			layer.confirm('Confirm login account[' + idnumber + ']？', {
				title:"Login confirmation",
				time: 0 //不自动关闭
				,btn: ['confirm', 'cancel']
				,yes: function(index){
					layer.close(index);
					confirmId = idnumber;
					// 关闭选择账号的open弹出框
					$("#accountContent").html("");
					$("#choose_id").hide();
					// 执行登录流程
					loginBtnTrue();
				}
			});
		}
	})

}


function loginBtn(){

	var $phone = $("#phone");
	var $phoneCode = $("#phoneCode");
	var $imgCode = $("#code");

	var phone = $phone.val().trim();
	var imgCode = $imgCode.val().trim();
	var phoneCode = $phoneCode.val().trim();
	if(phone === ""){
		$phone.focus();
		$phone.parent().addClass("login_error_border");
		// 手机号不能为空
		$("#errormsg").text(lang=='cn'?"\u624b\u673a\u53f7\u4e0d\u80fd\u4e3a\u7a7a\u3002":"Phone number cannot be empty");
		$("#errormsg").show();
		return ;
	}
	if(imgCode === ""){
		$imgCode.focus();
		$imgCode.parent().addClass("login_error_border");
		// 图形验证码不能为空
		$("#errormsg").text(lang=='cn'?"\u56fe\u5f62\u9a8c\u8bc1\u7801\u4e0d\u80fd\u4e3a\u7a7a\u3002":"The graphic verification code cannot be empty");
		$("#errormsg").show();
		return ;
	}
	if(phoneCode === ""){
		$phoneCode.focus();
		$phoneCode.parent().addClass("login_error_border");
		//短信验证码不能为空
		$("#errormsg").text(lang=='cn'?"\u77ed\u4fe1\u9a8c\u8bc1\u7801\u4e0d\u80fd\u4e3a\u7a7a\u3002":"SMS verification code cannot be empty");
		$("#errormsg").show();
		return ;
	}
	var mreg = /^0?1\d{10}$/;

	if(!mreg.test(phone)){
		$phone.focus();
		$phone.parent().addClass("login_error_border");
		//手机号格式不正确
		$("#errormsg").text(lang=='cn'?"\u624b\u673a\u53f7\u683c\u5f0f\u4e0d\u6b63\u786e\u3002":"The phone number format is incorrect");
		$("#errormsg").show();
		return ;
	}

	// 这里开始判断用户的验证码
	$.ajax({
		type: "get",
		async: false,
		url: "mobilecode?phone=" + phone + "&phoneCode=" + phoneCode + "&code=" + imgCode + "&method=isPhone2&" + Math.random(),
		success:function(result) {
			if (result.success) {
				// 校验成功，选择账号登录
				var userinfo = result.userinfo;
				if (userinfo.length === 1) {
					// 手机号对应唯一的账号，直接登陆
					confirmId = userinfo[0].ID_NUMBER;
					loginBtnTrue();
				} else if (userinfo.length > 1) {
					// 手机号对应多个账号，进入选择流程
					chooseMobileAccount(userinfo);
				} else {
					//登录异常，请稍后再试。
					$("#errormsg").text(lang=='cn'?"\u767b\u5f55\u5f02\u5e38\uff0c\u8bf7\u7a0d\u540e\u518d\u8bd5":"Abnormal Login; please try again later");
					$("#errormsg").show();
				}
			} else {
				// 验证码错误，提示信息
				var errcode = result.errcode;
				if(errcode!=null && errcode!=='' && errcode==='img_code_error') {
					$.cookie("mobile_error_info", null);
					//图形验证码错误，请重新输入
					$("#errormsg").text(lang=='cn'?"\u56fe\u5f62\u9a8c\u8bc1\u7801\u9519\u8bef\uff0c\u8bf7\u91cd\u65b0\u8f93\u5165":"Incorrect graphic verification code; please re-enter");
					$("#errormsg").show();
					$.cookie("mobile_error_info", null);
				} else if(errcode!=null && errcode!=='' && errcode==='phone_code_error') {
					$.cookie("mobile_error_info", null);
					//手机短信验证码错误，请重新输入
					$("#errormsg").text(lang=='cn'?"\u624b\u673a\u77ed\u4fe1\u9a8c\u8bc1\u7801\u9519\u8bef\uff0c\u8bf7\u91cd\u65b0\u8f93\u5165":"Incorrect SMS verification code error; please re-enter");
					$("#errormsg").show();
				} else if(errcode!=null && errcode!=='' && errcode==='phone_code_expire') {
					$.cookie("mobile_error_info", null);
					//验证码过期，请重新获取
					$("#errormsg").text(lang=='cn'?"\u9a8c\u8bc1\u7801\u8fc7\u671f\uff0c\u8bf7\u91cd\u65b0\u83b7\u53d6":"The verification code has expired; please get it again");
					$("#errormsg").show();
				}
				$("#codeImage_mobile").attr("src", "code?"+Math.random()) ;
			}
		}
	});
}

// 手机登录的表单提交
function loginBtnTrue() {
	var $phone = $("#phone");
	var $phoneCode = $("#phoneCode");

	var phoneCode = $phoneCode.val().trim();

	// 然后提交登陆表单
	$phone.attr("disabled","disabled");
	$phoneCode.attr("disabled","disabled");

	var lt = $("#lt").val();

	$("#ul").val(confirmId.length);
	$("#pl").val(phoneCode.length);
	$("#rsa").val(strEnc(confirmId+phoneCode+lt , '1' , '2' , '3'));
	$("#sl").val(1);
	$.cookie("is_mobile", "true");
	if($("#rememberPhone").is(":checked")){
		$.cookie('dlut_cas_phone' , $phone , { expires: 365});
	}
	$("#loginForm")[0].submit();
}

function login(){
	
	let $u = $("#un") , $p=$("#pd");
	
	let u = $u.val().trim();
	if(u==""){
		$u.focus();
		//账号不能为空
		$("#errormsg").text(lang=='cn'?"\u8d26\u53f7\u4e0d\u80fd\u4e3a\u7a7a\u3002":"username cannot be empty");
		$("#errormsg").show();
		return ;
	}
	
	let p = $p.val().trim();
	if(p==""){
		$p.focus();
		//密码不能为空
		$("#errormsg").text(lang=='cn'?"\u5bc6\u7801\u4e0d\u80fd\u4e3a\u7a7a\u3002":"password cannot be empty");
		$("#errormsg").show();
		return ;
	}
	
	$u.attr("disabled","disabled");
	$p.attr("disabled","disabled");
	
	let lt = $("#lt").val();
	
	$("#ul").val(u.length);
	$("#pl").val(p.length);
	$("#sl").val(0);
	$("#rsa").val(strEnc(u+p+lt , '1' , '2' , '3'));
	if($("#rememberName").is(":checked")){
		$.cookie('dlut_cas_un' , u , { expires: 365});
	}
	$("#loginForm")[0].submit();
}
function setQrcode(content){
	$("#qrcode").qrcode({width: 143,height: 143,text: content});
}
function qrcodeLogin(content, token, num){
	var	search =location.search;
	//跳转url
	var service = getParameter(search, "service", "");
	$.ajax({
        type : "get",      
        url : "qrcodesso", 
        dataType : "text",
        cache: false ,
        data :
        {
        	 "type"    : "qrcodeLogin",
             "service" : service,
             "token"   : token,
             "content" : content
        },
        success : function(result)
        {
        	num ++;
        	if(result == "out" && num < 2){
        		qrcodeLogin(content, token, num);
        	}else{
        		window.location.href = decodeURIComponent(service);
        	}
        	window.location.href = decodeURIComponent(service);
        	if(result == "ok"){
        		window.location.href = decodeURIComponent(service);
        	}else if(result == "out"){
//        		alert("扫码超时");
        		window.location.href = decodeURIComponent(service);
        	}else if(result == "error"){
        		alert("二维码失效");
        	}
        },
        error : function(xhr, status, errMsg)
        {
             alert("扫码失败刷新后重试");
        }
    });
}
function setFaceQrcode(content){
	$("#faceQrCode").qrcode({width: 143,height: 143,text: content});
}
function faceQrCodeLogin(content, token, num){
	var	search =location.search;
	//跳转url
	var service = getParameter(search, "service", "");
	$.ajax({
        type : "get",
        url : "qrcodesso",
        dataType : "text",
        cache: false ,
        data :
        {
        	 "type"    : "qrcodeLogin",
             "service" : service,
             "token"   : token,
             "content" : content
        },
        success : function(result)
        {
        	num ++;
        	if(result == "out" && num < 2){
        		qrcodeLogin(content, token, num);
        	}else{
        		window.location.href = decodeURIComponent(service);
        	}
        	window.location.href = decodeURIComponent(service);
        	if(result == "ok"){
        		window.location.href = decodeURIComponent(service);
        	}else if(result == "out"){
//        		alert("扫码超时");
        		window.location.href = decodeURIComponent(service);
        	}else if(result == "error"){
        		alert("二维码失效");
        	}
        },
        error : function(xhr, status, errMsg)
        {
            alert("扫码失败刷新后重试");
        }
    });
}

function getParameter(hash,name,nvl) {
	if(!nvl){
		nvl = "";
	}
	var svalue = hash.match(new RegExp("[\?\&]?" + name + "=([^\&\#]*)(\&?)", "i"));
	if(svalue == null){
		return nvl;
	}else{
		svalue = svalue ? svalue[1] : svalue;
		svalue = svalue.replace(/<script>/gi,"").replace(/<\/script>/gi,"").replace(/<html>/gi,"").replace(/<\/html>/gi,"").replace(/alert/gi,"").replace(/<span>/gi,"").replace(/<\/span>/gi,"").replace(/<div>/gi,"").replace(/<\/div>/gi,"");
		return svalue;
	}
}

function replaceHash (paramValue){
	if(paramValue!=null&&paramValue.indexOf("portal.dlut.edu.cn")!=-1&&paramValue.indexOf("https")==-1){
		paramValue = paramValue.replace("http","https");
		window.location.href = paramValue;
	}
}
//获取地址栏参数值 	
function GetQueryString(service) {
	var b = new RegExp("(^|&)" + service + "=([^&]*)(&|$)");
	var r = window.location.search.substr(1).match(b);
	if (r != null) return unescape(r[2]);
	return null
};
