function tellSU(element)
{
	id=element.id
	value=element.value.replace(/'/,"\\'")
	window.location='skp:ValueChanged@'+id +"|"+ value;
}

function tellSUcb(element)
{
	id=element.id
	value=element.checked
	window.location='skp:ValueChanged@'+id +"|"+ value;
}


function createOption(id,option_name)
{
	var op=document.createElement('option');
	op.text=option_name
	op.value=option_name
	document.getElementById(id).add(op);
}

function clearList(id)
{
	list=document.getElementById(id)
	list_length=list.length
	for (i=0;i<list_length;i++){
	list.remove(0)
	}
}

function detectIE() {
    var ua = window.navigator.userAgent;

    var msie = ua.indexOf('MSIE ');
    if (msie > 0) {
        // IE 10 or older => return version number
        return true;
    }

    var trident = ua.indexOf('Trident/');
    if (trident > 0) {
        // IE 11 => return version number
       return true;
    }

    var edge = ua.indexOf('Edge/');
    if (edge > 0) {
      return true;
    }

    // other browser
    return false;
}

//Credit to Julia Eneroth for this code
function port_key(){
  //Sends the keycode from the event to a Ruby callback.
  //This can be used for web dialogs inside a custom tools to send key events to the tool to change its behavior even when the web dialog is focused.
  //Run "document.onkeyup=port_key;" to initialize. onkeyup is used to avoid overriding calls to onkeydown already in use in the dialog. onkeypress doesn't fire for modifier keys.
  e = window.event || e;
  keycode = e.keyCode || e.which
  
  //It might be wise to only proceed for certain keys here, e.g. modifier keys or whatever keys are used in the tool.
  
  window.location='skp:port_key@' + keycode;
}