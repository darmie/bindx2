package bindx;

#if macro

import bindx.GenericError;
import haxe.macro.Expr;
import haxe.macro.MacroStringTools;
import haxe.macro.Type;
import haxe.macro.Context;
import haxe.macro.Printer;

using Lambda;
using StringTools;
using haxe.macro.Tools;

typedef FieldExpr = {
    var field:ClassField;
    var bindable:Bool;
    var e:Expr;
    @:optional var params:Array<Expr>;
}

typedef Chain = {
    var init:Array<Expr>;
    var bind:Array<Expr>;
    var unbind:Array<Expr>;
    var expr:Expr;
}
#end

@:access(bindx.BindMacros)
@:access(bindx.Bind)
class BindExt {
    
    @:noUsing macro static public function expr<T>(expr:ExprOf<T>, listener:ExprOf<Null<T>->Null<T>->Void>):ExprOf<Void->Void> {
        return internalBindExpr(expr, listener);
    }
    
    @:noUsing macro static public function exprTo<T>(expr:ExprOf<T>, target:ExprOf<T>):ExprOf<Void->Void> {
        var type = Context.typeof(expr).toComplexType();
        return internalBindExpr(expr, macro function (_, to:Null<$type>) $target = to);
    }
    
    @:noUsing macro static public function chain<T>(expr:ExprOf<T>, listener:Expr):ExprOf<Void->Void> {
        return internalBindChain(expr, listener);
    }
    
    @:noUsing macro static public function chainTo<T>(expr:ExprOf<T>, target:ExprOf<T>):ExprOf<Void->Void> {
        var type = Context.typeof(expr).toComplexType();
        return internalBindChain(expr, macro function (_, to:Null<$type>) $target = to);
    }
    
    #if macro
    
    static inline function internalBindChain(expr:Expr, listener:Expr):Expr {
        var zeroListener = listenerName(0, "");
        var chain = null;
        try { chain = warnPrepareChain(expr, macro $i{ zeroListener }); } catch (e:GenericError) e.contextError();
        
        return macro (function ($zeroListener):Void->Void
            $b { chain.init.concat(chain.bind).concat([(macro var res = function ():Void $b { chain.unbind }), macro return res]) }
        )($listener);
    }
    
    static inline function unwrapFormatedString(expr:Expr):Expr {
        return if (MacroStringTools.isFormatExpr(expr)) {
            var f = switch (expr.expr) {
                case EConst(CString(s)): s;
                case _: null;
            }
            if (f != null) MacroStringTools.formatString(f, expr.pos) else expr;
        } else expr;
    }
    
    static function internalBindExpr(expr:Expr, listener:Expr):Expr {
        var type = Context.typeof(expr).toComplexType();
        var listenerNameExpr = macro listener;
        var fieldListenerName = "fieldListener";
        var fieldListenerNameExpr = macro $i{fieldListenerName};
        var methodListenerName = "methodListener";
        var methodListenerNameExpr = macro $i{methodListenerName};
        var chain:Chain = { init:[], bind:[], unbind:[], expr:expr };
        var binded:Map<String, {prebind:Expr, c:Chain}> = new Map();
        
        var prefix = 0;
        function findChain(expr:Expr) {
            var isChain;
            expr = unwrapFormatedString(expr);
            var e = expr;
            var ecall = false;
            do switch (e.expr) {
                case EField(le, _) | ECall(le, _): 
                    isChain = true;
                    ecall = e.expr.match(ECall(_, _));
                    e = le;
                case _:
                    isChain = false;
            } while (isChain);
            var doBind = e != expr;
            if (doBind) {
                var key = expr.toString();
                for (k in binded.keys()) if (k.startsWith(key)) {
                    doBind = false;
                    break;
                }
            }
            if (doBind) {
                var pre = '_${prefix++}';
                var zeroListener = listenerName(0, pre);
                var c = null;
                try { 
                    c = warnPrepareChain(expr, macro $i { zeroListener }, pre, true); 
                } catch (e:GenericError) {
                    Warn.w('${expr.toString()} is not bindable.', e.pos, WarnPriority.ALL);
                }
                if (c != null) {
                    var key = c.expr.toString();
                    if (!binded.exists(key)) {
                        var prebind = macro var $zeroListener = ${ecall ? methodListenerNameExpr : fieldListenerNameExpr};
                        binded.set(key, {prebind:prebind, c:c});
                    }
                }
            }
            expr.iter(findChain);
        }
        findChain(expr);
        
        var keys = [for (k in binded.keys()) k];
        var i = 0;
        while (i < keys.length) {
            var k = keys[i];
            var remove = false;
            var j = i;
            while (!remove && ++j < keys.length) remove = keys[j].startsWith(k);
            if (remove) keys = keys.splice(i, 1); else i++;
        }
        
        var msg = [];
        for (k in keys) {
            var data = binded.get(k);
            msg.push(data.c.expr.toString());
            chain.bind.unshift(data.prebind);
            var c = data.c;
            chain.init = chain.init.concat(c.init);
            chain.bind = chain.bind.concat(c.bind);
            chain.unbind = chain.unbind.concat(c.unbind);
        }
        Warn.w('Bind \'${msg.join("', '")}\'', expr.pos, WarnPriority.INFO);
        
        var zeroListener = listenerName(0, "");
        var zeroValue = 'value0';
        chain.unbind.unshift(macro $i { zeroValue } = null);
        
        var callListener = switch (type) {
            case macro : Void: macro if (!init) $i{zeroListener}();
            case _: macro if (!init) { var v:Null<$type> = null; try { v = $expr; } catch (e:Dynamic) { }; $i{zeroListener}($i{zeroValue}, $i{zeroValue} = v); }; 
        }

        var preInit = [
            (macro var init:Bool = true),
            macro var $zeroValue:Null<$type> = null
        ];
        
        var postInit = [
            macro function $fieldListenerName(?from:Dynamic, ?to:Dynamic) $callListener,
            macro function $methodListenerName() $callListener
        ];
        
        var result = [macro init = false, macro $i { methodListenerName } (), (macro var res = function ():Void $b { chain.unbind }), macro return res ];
        
        return macro (function ($zeroListener):Void->Void
            $b { preInit.concat(chain.init).concat(postInit).concat(chain.bind).concat(result) }
        )($listener);
    }
    
    static function checkFields(expr:Expr):Array<FieldExpr> {
        var first = Bind.checkField(expr);
        if (first.field == null) {
            if (first.error != null) throw first.error;
            else throw new FatalError('${expr.toString()} is not bindable.', expr.pos);
        }
        
        var prevField = {e:first.e, field:first.field, error:null};
        var fields:Array<FieldExpr> = [ { field:first.field, bindable:first.error == null, e:first.e } ];
        
        var end = false;
        while (!end) {
            end = true;
            var field = Bind.checkField(prevField.e);
            if (field.field != null) {
                fields.push( { field:field.field, bindable:field.error == null, e:field.e } );
                end = false;
            } else if (field.error != null) switch (prevField.e.expr) {
                case ECall(e, params):
                    field = Bind.checkField(e);
                    if (field.field == null) throw new FatalError('${e.toString()} is not bindable.', expr.pos);
                    else fields.push( { e:field.e, field:field.field, params:params, bindable:field.error == null } );
                    end = false;
                case _:
            }
            else if (field.e == null) {
                throw new FatalError('${prevField.e.toString()} is not bindable.', prevField.e.pos);
            }
            prevField = field;
        }
        return fields;
    }
    
    static function warnPrepareChain(expr:Expr, listener:Expr, prefix = "", skipUnbindable = false):Chain {
        var fields = checkFields(expr);

        if (fields.length == 0)
            throw new FatalError('Can\'t bind empty expression: ${expr.toString()}', expr.pos);

        var i = fields.length;
        var first = null;
        while (i-- > 0) {
            var f = fields[i];
            if (first != null) f.bindable = false;
            else if (!f.bindable && first == null) {
                first = f;
                if (skipUnbindable) {
                    fields = fields.splice(i+1, fields.length - i);
                    break;
                }
            }
        }
        var bindableNum = fields.fold(function (it, n) return n += it.bindable ? 1 : 0, 0);
        if (bindableNum == 0) {
            throw new GenericError('${expr.toString()} is not bindable.', expr.pos);
            return null;
        }
        if (first != null)
            Warn.w('${expr.toString()} is not full bindable. Can bind only "${first.e.toString()}".', expr.pos, WarnPriority.INFO);
        
        return prepareChain(fields, macro listener, expr, prefix);
    }
    
    inline static function listenerName(idx:Int, prefix) return '${prefix}listener$idx';
    
    static function prepareChain(fields:Array<FieldExpr>, expr:Expr, listener:Expr, prefix = ""):Chain {
        var res:Chain = { init:[], bind:[], unbind:[], expr:null };
        
        var prevListenerName = listenerName(0, prefix);
        var prevListenerNameExpr = macro $i { prevListenerName };
        var zeroListener = fields[0].bindable ? { f:fields[0], l:prevListenerNameExpr } : null;
        if (zeroListener != null) {
            var fn = zeroListener.f.field.name;
            res.expr = macro @:pos(zeroListener.f.e.pos) ${zeroListener.f.e}.$fn;
        }
        var i = -1;
        while (++i < fields.length - 1) {
            var field = fields[i + 1];
            var prev = fields[i];
            var type = Context.typeof(field.e).toComplexType();
            var listenerName = listenerName(i+1, prefix);
            var listenerNameExpr = macro $i { listenerName };
            
            var value = '${prefix}value${i+1}';
            var valueExpr = macro $i { value };
            
            var oldValue = '${prefix}oldValue${i+1}';
            var oldValueExpr = macro $i { oldValue };
            
            var fieldName = prev.field.name;
            var e = prev.e;
            
            var fieldListenerBody = [];
            var fieldListener;
            
            if (field.bindable) zeroListener = { f:field, l:listenerNameExpr };
            
            if (prev.bindable && res.expr == null) {
                var fn = prev.field.name;
                res.expr = macro @:pos(prev.e.pos) ${prev.e}.$fn;
            }

            if (prev.bindable) {
                var unbind = BindMacros.bindingSignalProvider.getClassFieldUnbindExpr(valueExpr, prev.field, prevListenerNameExpr );
                
                res.bind.push(macro var $value:Null<$type> = null );
                res.unbind.push(macro if ($valueExpr != null) { $unbind; $valueExpr = null; } );
                
                fieldListenerBody.push(macro if ($valueExpr != null) $unbind );
                fieldListenerBody.push(macro $valueExpr = n );
                fieldListenerBody.push(macro if (n != null)
                    $ { BindMacros.bindingSignalProvider.getClassFieldBindExpr(macro n, prev.field, prevListenerNameExpr ) });
            }
            var callPrev = macro $prevListenerNameExpr($a { prev.params != null ? [] : [macro o != null ? o.$fieldName : null, macro n != null ? n.$fieldName : null] } );
            fieldListenerBody.push(callPrev);
        
            if (field.params != null) {
                fieldListenerBody.unshift(macro var n:Null<$type> = $i{oldValue} = try $e catch (e:Dynamic) null );
                fieldListenerBody.unshift(macro var o:Null<$type> = $i{oldValue} );
                
                res.init.push(macro var $oldValue:Null<$type> = null);
                res.unbind.push(macro $oldValueExpr = null);
                
                fieldListener = macro function $listenerName ():Void $b { fieldListenerBody };
            } else {
                if (prev.bindable) {
                    fieldListenerBody.unshift(macro if (o != null) 
                        ${BindMacros.bindingSignalProvider.getClassFieldUnbindExpr(macro o, prev.field, prevListenerNameExpr )}
                    );
                }
                fieldListener = macro function $listenerName (o:Null<$type>, n:Null<$type>):Void $b { fieldListenerBody };
            }
        
            res.bind.push(fieldListener);
            
            prevListenerName = listenerName;
            prevListenerNameExpr = listenerNameExpr;
        }
        
        if (zeroListener == null || zeroListener.f.bindable == false)
            throw new GenericError('${expr.toString()} is not bindable.', expr.pos);
            
        var zeroName = zeroListener.f.e.toString();
        if (zeroName != "this")
            res.init.unshift(macro var $zeroName = $i{zeroName});
        
        res.bind.push(BindMacros.bindingSignalProvider.getClassFieldBindExpr(macro $i{zeroName}, zeroListener.f.field, zeroListener.l ));
        res.unbind.push(BindMacros.bindingSignalProvider.getClassFieldUnbindExpr(macro $i{zeroName}, zeroListener.f.field, zeroListener.l ));

        if (zeroListener.f.params != null) {
            res.bind.push(macro ${zeroListener.l}());
        } else {
            var fieldName = zeroListener.f.field.name;
            res.bind.push(macro $ { zeroListener.l } (null, $ { zeroListener.f.e } .$fieldName ));
        }
        return res;
    }
    #end
}