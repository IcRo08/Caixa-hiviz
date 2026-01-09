import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// --- CONFIGURAÇÕES GERAIS ---
const String SUPABASE_URL = 'https://ukzkiijpldsjzhpftumk.supabase.co';
const String SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVremtpaWpwbGRzanpocGZ0dW1rIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjcxMjk4MzksImV4cCI6MjA4MjcwNTgzOX0.KybTo0IPM5atFgwlQ4o4yKcQyC053fv2dXBR08-0TJA';
const String MINHA_CHAVE_PIX = '00020126580014br.gov.bcb.pix013662977c57-7272-4339-806f-521a9793ae745204000053039865802BR5925ZILDETE FELICIANO DE OLIV6014RIO DE JANEIRO622805242323c63027b57159ab70d0b76304595F';
const String NOME_LOJA = "HIVIZ ACESSÓRIOS";

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: SUPABASE_URL, anonKey: SUPABASE_KEY);
  try {
    await Supabase.instance.client.auth.signInWithPassword(
      email: 'caixa01@hiviz.com', // Crie esse user no Supabase
      password: 'vendahiviz1944'
    );
  } catch (e) {
    print("Erro ao logar caixa: $e");
  }
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const AppCaixaTV());
}

class AppCaixaTV extends StatelessWidget {
  const AppCaixaTV({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Caixa TV',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(primary: Colors.deepPurple, secondary: Colors.greenAccent),
      ),
      home: const CaixaPage(),
    );
  }
}

class CaixaPage extends StatefulWidget {
  const CaixaPage({super.key});

  @override
  State<CaixaPage> createState() => _CaixaPageState();
}

class _CaixaPageState extends State<CaixaPage> {
  List<Map<String, dynamic>> _produtosEstoque = [];
  final List<Map<String, dynamic>> _carrinho = [];

  final FocusNode _focusNodeInput = FocusNode();
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  int _quantidadeMultiplicador = 1;
  bool _loading = true;

  // --- VARIÁVEIS DE CONFIGURAÇÃO (TAXAS) ---
  double _taxaDebito = 1.90;
  double _taxaCreditoVista = 3.10;
  Map<String, double> _taxasParcelado = {
    "2": 4.60, "3": 5.90, "4": 7.30, "5": 8.60, "6": 9.90,
    "7": 11.30, "8": 12.60, "9": 13.90, "10": 15.30, "11": 16.60, "12": 18.00
  };

  @override
  void initState() {
    super.initState();
    _carregarProdutos();
    _carregarConfiguracoes();
  }

  Future<void> _carregarConfiguracoes() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _taxaDebito = prefs.getDouble('taxa_debito') ?? 1.90;
      _taxaCreditoVista = prefs.getDouble('taxa_credito_vista') ?? 3.10;

      String? parceladoJson = prefs.getString('taxas_parcelado');
      if (parceladoJson != null) {
        Map<String, dynamic> decoded = jsonDecode(parceladoJson);
        _taxasParcelado = decoded.map((key, value) => MapEntry(key, (value as num).toDouble()));
      }
    });
  }

  void _abrirConfiguracoes() {
    showDialog(
      context: context,
      builder: (context) => DialogConfiguracao(
        taxaDebito: _taxaDebito,
        taxaCreditoVista: _taxaCreditoVista,
        taxasParcelado: _taxasParcelado,
        onSalvar: (d, c, p) async {
          setState(() {
            _taxaDebito = d;
            _taxaCreditoVista = c;
            _taxasParcelado = p;
          });
          final prefs = await SharedPreferences.getInstance();
          await prefs.setDouble('taxa_debito', d);
          await prefs.setDouble('taxa_credito_vista', c);
          await prefs.setString('taxas_parcelado', jsonEncode(p));
        },
      ),
    ).then((_) => _manterFoco());
  }

  Future<void> _carregarProdutos() async {
    try {
      final data = await Supabase.instance.client.from('produtos').select('id, nome, preco, codigo_barras, estoque');
      setState(() {
        _produtosEstoque = List<Map<String, dynamic>>.from(data);
        _loading = false;
      });
      _manterFoco();
    } catch (e) {
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Erro: $e")));
    }
  }

  void _manterFoco() {
    if (!_focusNodeInput.hasFocus) {
      _focusNodeInput.requestFocus();
    }
  }

  // --- LÓGICA CORRIGIDA AQUI PARA ACEITAR MÚLTIPLOS CÓDIGOS ---
  void _processarInput(String valorOriginal) {
    String valor = valorOriginal.trim();
    if (valor.isEmpty) { _manterFoco(); return; }

    final codeLido = valor.toLowerCase();

    final produtoEncontrado = _produtosEstoque.firstWhere(
      (p) {
        // 1. Pega a string inteira do banco (ex: "789, 123, 456")
        final String rawCodes = (p['codigo_barras'] ?? '').toString().toLowerCase();

        // 2. Quebra nas vírgulas criando uma lista (ex: ["789", " 123", " 456"])
        final List<String> listaCodigos = rawCodes.split(',');

        // 3. Verifica se ALGUM código da lista bate com o que foi lido (usando trim para limpar espaços)
        return listaCodigos.any((code) => code.trim() == codeLido);
      },
      orElse: () => {},
    );

    if (produtoEncontrado.isNotEmpty) {
      _adicionarAoCarrinho(produtoEncontrado);
      setState(() => _quantidadeMultiplicador = 1);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Produto não encontrado: $valor"), backgroundColor: Colors.red, duration: const Duration(milliseconds: 1500)));
    }
    _inputController.clear();
    Future.delayed(const Duration(milliseconds: 10), () => _manterFoco());
  }
  // ------------------------------------------------------------

  void _adicionarAoCarrinho(Map<String, dynamic> produto) {
    setState(() {
      final indexExistente = _carrinho.indexWhere((item) => item['id'] == produto['id']);
      if (indexExistente >= 0) {
        _carrinho[indexExistente]['quantidade'] += _quantidadeMultiplicador;
      } else {
        final novoItem = Map<String, dynamic>.from(produto);
        novoItem['quantidade'] = _quantidadeMultiplicador;
        _carrinho.add(novoItem);
      }
    });
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollController.hasClients) _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  void _removerDoCarrinho(int index) {
    setState(() { _carrinho.removeAt(index); });
  }

  double get _total => _carrinho.fold(0.0, (sum, item) {
    return sum + ((item['preco'] as num).toDouble() * (item['quantidade'] as int));
  });

  void _abrirPagamento() {
    if (_carrinho.isEmpty) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => DialogPagamento(
        total: _total,
        taxaDebito: _taxaDebito,
        taxaCreditoVista: _taxaCreditoVista,
        taxasParcelado: _taxasParcelado,
        onFinalizar: (tipo, valorFinal) => _fecharVenda(tipo, valorFinal),
      ),
    ).then((_) => _manterFoco());
  }

  Future<void> _imprimirRecibo(List<Map<String, dynamic>> itensVendidos, double subtotal, double valorFinal, String tipoPagamento, double valorPago, double troco) async {
    final doc = pw.Document();
    final real = NumberFormat.currency(locale: 'pt_BR', symbol: 'R\$');
    final agora = DateFormat('dd/MM/yyyy HH:mm').format(DateTime.now());
    final double valorTaxa = valorFinal - subtotal;

    pw.Widget _buildContent(String tituloVia) {
      return pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Center(child: pw.Text(NOME_LOJA, style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 16))),
          pw.Center(child: pw.Text("--- $tituloVia ---", style: const pw.TextStyle(fontSize: 10))),
          pw.Center(child: pw.Text(agora, style: const pw.TextStyle(fontSize: 10))),
          pw.Divider(),
          pw.Row(children: [
            pw.Expanded(flex: 4, child: pw.Text('Item', style: const pw.TextStyle(fontSize: 10))),
            pw.Expanded(flex: 1, child: pw.Text('Qtd', style: const pw.TextStyle(fontSize: 10))),
            pw.Expanded(flex: 2, child: pw.Text('Val', style: const pw.TextStyle(fontSize: 10))),
          ]),
          pw.Divider(thickness: 0.5),
          ...itensVendidos.map((item) {
            final totalItem = (item['preco'] as num) * (item['quantidade'] as int);
            return pw.Row(children: [
              pw.Expanded(flex: 4, child: pw.Text(item['nome'], style: const pw.TextStyle(fontSize: 10))),
              pw.Expanded(flex: 1, child: pw.Text('${item['quantidade']}x', style: const pw.TextStyle(fontSize: 10))),
              pw.Expanded(flex: 2, child: pw.Text(real.format(totalItem), style: const pw.TextStyle(fontSize: 10))),
            ]);
          }).toList(),
          pw.Divider(),
          pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
            pw.Text('Subtotal:', style: const pw.TextStyle(fontSize: 10)),
            pw.Text(real.format(subtotal), style: const pw.TextStyle(fontSize: 10)),
          ]),
          if (valorTaxa > 0.05)
            pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
              pw.Text('Taxa Maq.:', style: const pw.TextStyle(fontSize: 10)),
              pw.Text(real.format(valorTaxa), style: const pw.TextStyle(fontSize: 10)),
            ]),
            pw.SizedBox(height: 2),
            pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
              pw.Text('TOTAL:', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
              pw.Text(real.format(valorFinal), style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
            ]),
            pw.SizedBox(height: 5),
            pw.Text('Pagamento: $tipoPagamento', style: const pw.TextStyle(fontSize: 10)),
            if (tipoPagamento == 'DINHEIRO') ...[
              pw.Text('Pago: ${real.format(valorPago)}', style: const pw.TextStyle(fontSize: 10)),
              pw.Text('Troco: ${real.format(troco)}', style: const pw.TextStyle(fontSize: 10)),
            ],
            pw.SizedBox(height: 10),
            pw.Center(child: pw.Text('Obrigado pela preferencia!', style: const pw.TextStyle(fontSize: 10))),
            pw.SizedBox(height: 20),
        ],
      );
    }

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.roll80,
        margin: const pw.EdgeInsets.all(5),
        build: (pw.Context context) {
          return pw.Column(children: [
            _buildContent("VIA CLIENTE"),
            pw.Padding(padding: const pw.EdgeInsets.symmetric(vertical: 10), child: pw.Text("- - - - - - - CORTE AQUI - - - - - - -", style: const pw.TextStyle(fontSize: 8))),
            _buildContent("VIA LOJA"),
          ]);
        },
      ),
    );

    final bytes = await doc.save();

    try {
      Directory? diretorio = Platform.isAndroid ? await getExternalStorageDirectory() : await getDownloadsDirectory();
      diretorio ??= await getApplicationDocumentsDirectory();
      final file = File('${diretorio.path}/recibo_${DateTime.now().millisecondsSinceEpoch}.pdf');
      await file.writeAsBytes(bytes);
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("PDF Salvo: ${file.path}"), backgroundColor: Colors.blue));
    } catch(e) { print(e); }

    try {
      final printers = await Printing.listPrinters();
      if (printers.isNotEmpty) {
        await Printing.directPrintPdf(printer: printers.first, onLayout: (format) async => bytes);
      } else {
        await Printing.sharePdf(bytes: bytes, filename: 'recibo_caixa.pdf');
      }
    } catch (e) {
      await Printing.sharePdf(bytes: bytes, filename: 'recibo_erro_backup.pdf');
    }
  }

  Future<void> _fecharVenda(String tipoPagamento, double valorFinal) async {
    Navigator.pop(context);
    final listaRecibo = List<Map<String, dynamic>>.from(_carrinho);
    final double subtotalVenda = _total;
    final double totalFinalVenda = valorFinal;
    double valorPagoPeloCliente = valorFinal;
    double troco = 0.0;

    setState(() => _loading = true);

    try {
      final supabase = Supabase.instance.client;
      for (var item in _carrinho) {
        final int qtdVendida = (item['quantidade'] as num).toInt();
        final int estoqueAntigo = (item['estoque'] as num?)?.toInt() ?? 0;
        final int novoEstoque = estoqueAntigo - qtdVendida;
        await supabase.from('produtos').update({'estoque': novoEstoque}).eq('id', item['id']);
      }

      await supabase.from('vendas').insert({
        'total': totalFinalVenda,
        'tipo_pagamento': tipoPagamento,
        'itens': _carrinho.map((e) => {'nome': e['nome'], 'preco': e['preco'], 'quantidade': e['quantidade']}).toList(),
      });

      await _carregarProdutos();

      setState(() { _carrinho.clear(); _loading = false; _quantidadeMultiplicador = 1; });

      if (mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            backgroundColor: Colors.grey[900],
            title: const Text("Venda Concluída!", style: TextStyle(color: Colors.white)),
            content: const Text("Deseja imprimir o comprovante?", style: TextStyle(color: Colors.white70)),
            actions: [
              TextButton(onPressed: () { Navigator.pop(ctx); _manterFoco(); }, child: const Text("NÃO", style: TextStyle(color: Colors.grey))),
              ElevatedButton.icon(
                icon: const Icon(Icons.print),
                label: const Text("SIM, IMPRIMIR"),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurple),
                onPressed: () {
                  Navigator.pop(ctx);
                  _imprimirRecibo(listaRecibo, subtotalVenda, totalFinalVenda, tipoPagamento, valorPagoPeloCliente, troco);
                  _manterFoco();
                },
              ),
            ],
          ),
        );
      }
    } catch (e) {
      setState(() => _loading = false);
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Erro: $e")));
    }
  }

  @override
  Widget build(BuildContext context) {
    final real = NumberFormat.currency(locale: 'pt_BR', symbol: 'R\$');
    return Scaffold(
      appBar: AppBar(
        title: const Text("Caixa TV"),
        backgroundColor: Colors.grey[900],
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: "Configurar Taxas",
            onPressed: _abrirConfiguracoes,
          )
        ],
      ),
      body: GestureDetector(
        onTap: _manterFoco,
        behavior: HitTestBehavior.translucent,
        child: Row(
          children: [
            Expanded(
              flex: 7,
              child: Container(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("CAIXA LIVRE", style: TextStyle(color: Colors.grey, fontSize: 20, letterSpacing: 2)),
                    const Divider(color: Colors.grey),
                    Expanded(
                      child: _carrinho.isEmpty
                      ? const Center(child: Text("Passe o produto...", style: TextStyle(color: Colors.white24, fontSize: 30)))
                      : ListView.builder(
                        controller: _scrollController, itemCount: _carrinho.length,
                        itemBuilder: (ctx, i) {
                          final item = _carrinho[i];
                          final int qtd = item['quantidade'];
                          final double totalLinha = (item['preco'] as num).toDouble() * qtd;
                          return Card(
                            color: Colors.grey[900],
                            child: ListTile(
                              leading: CircleAvatar(backgroundColor: Colors.deepPurple, radius: 25, child: Text("${qtd}x", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold))),
                              title: Text(item['nome'], style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                              subtitle: Text("${real.format(item['preco'])} un.", style: const TextStyle(color: Colors.white54)),
                              trailing: Row(mainAxisSize: MainAxisSize.min, children: [Text(real.format(totalLinha), style: const TextStyle(color: Colors.greenAccent, fontSize: 22, fontWeight: FontWeight.bold)), const SizedBox(width: 15), IconButton(icon: const Icon(Icons.delete, color: Colors.red), onPressed: () => _removerDoCarrinho(i))]),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(children: [1, 2, 3, 4, 5].map((qtd) => Padding(padding: const EdgeInsets.only(right: 10), child: ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: _quantidadeMultiplicador == qtd ? Colors.deepPurple : Colors.grey[800], shape: const CircleBorder(), padding: const EdgeInsets.all(20)), onPressed: () { setState(() => _quantidadeMultiplicador = qtd); _manterFoco(); }, child: Text("$qtd")))).toList()),
                  ],
                ),
              ),
            ),
            Expanded(
              flex: 3,
              child: Container(
                color: Colors.grey[900], padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    TextField(controller: _inputController, focusNode: _focusNodeInput, autofocus: true, onSubmitted: _processarInput, keyboardType: TextInputType.visiblePassword, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: "Leitor Ativo", border: OutlineInputBorder(), prefixIcon: Icon(Icons.qr_code_scanner, color: Colors.greenAccent), filled: true, fillColor: Colors.black45)),
                    const Spacer(),
                    const Text("TOTAL A PAGAR", style: TextStyle(color: Colors.white54, fontSize: 16)),
                    FittedBox(child: Text(real.format(_total), style: const TextStyle(color: Colors.greenAccent, fontSize: 60, fontWeight: FontWeight.bold))),
                    const SizedBox(height: 30),
                    SizedBox(width: double.infinity, height: 80, child: ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurple), onPressed: _carrinho.isEmpty ? null : _abrirPagamento, child: const Text("FINALIZAR", style: TextStyle(color: Colors.white, fontSize: 24)))),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class DialogConfiguracao extends StatefulWidget {
  final double taxaDebito;
  final double taxaCreditoVista;
  final Map<String, double> taxasParcelado;
  final Function(double, double, Map<String, double>) onSalvar;

  const DialogConfiguracao({super.key, required this.taxaDebito, required this.taxaCreditoVista, required this.taxasParcelado, required this.onSalvar});

  @override
  State<DialogConfiguracao> createState() => _DialogConfiguracaoState();
}

class _DialogConfiguracaoState extends State<DialogConfiguracao> {
  late TextEditingController _debitoCtrl;
  late TextEditingController _creditoVistaCtrl;
  final Map<String, TextEditingController> _parceladoCtrls = {};

  @override
  void initState() {
    super.initState();
    _debitoCtrl = TextEditingController(text: widget.taxaDebito.toString());
    _creditoVistaCtrl = TextEditingController(text: widget.taxaCreditoVista.toString());

    for (int i = 2; i <= 12; i++) {
      _parceladoCtrls[i.toString()] = TextEditingController(text: (widget.taxasParcelado[i.toString()] ?? 0.0).toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("Configurar Taxas (%)"),
      content: SizedBox(
        width: 400,
        height: 500,
        child: SingleChildScrollView(
          child: Column(
            children: [
              _campo("Débito", _debitoCtrl),
              _campo("Crédito à Vista", _creditoVistaCtrl),
              const Divider(),
              const Text("Parcelamento (Total da Taxa)", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
              const SizedBox(height: 10),
              ...List.generate(11, (index) {
                int p = index + 2;
                return _campo("Crédito ${p}x", _parceladoCtrls[p.toString()]!);
              }),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text("CANCELAR")),
        ElevatedButton(
          onPressed: () {
            double d = double.tryParse(_debitoCtrl.text.replaceAll(',', '.')) ?? 0;
            double c = double.tryParse(_creditoVistaCtrl.text.replaceAll(',', '.')) ?? 0;
            Map<String, double> p = {};
            _parceladoCtrls.forEach((key, ctrl) {
              p[key] = double.tryParse(ctrl.text.replaceAll(',', '.')) ?? 0;
            });
            widget.onSalvar(d, c, p);
            Navigator.pop(context);
          },
          child: const Text("SALVAR"),
        )
      ],
    );
  }

  Widget _campo(String label, TextEditingController ctrl) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: TextField(
        controller: ctrl,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: label, suffixText: "%", border: const OutlineInputBorder(), isDense: true),
      ),
    );
  }
}

class DialogPagamento extends StatefulWidget {
  final double total;
  final double taxaDebito;
  final double taxaCreditoVista;
  final Map<String, double> taxasParcelado;
  final Function(String, double) onFinalizar;

  const DialogPagamento({super.key, required this.total, required this.taxaDebito, required this.taxaCreditoVista, required this.taxasParcelado, required this.onFinalizar});

  @override
  State<DialogPagamento> createState() => _DialogPagamentoState();
}

class _DialogPagamentoState extends State<DialogPagamento> {
  String _metodo = 'DINHEIRO';
  final _recebidoController = TextEditingController();
  final FocusNode _focoDinheiro = FocusNode();
  double _troco = 0.0;
  double _valorRecebidoDinheiro = 0.0;
  bool _isDebito = true;
  int _parcelas = 1;

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 300), () { if(_metodo == 'DINHEIRO') _focoDinheiro.requestFocus(); });
  }

  void _calcularTroco(String valor) {
    double recebido = double.tryParse(valor.replaceAll(',', '.')) ?? 0.0;
    setState(() { _valorRecebidoDinheiro = recebido; _troco = recebido - widget.total; });
  }

  double _calcularTotalCartao() {
    if (_isDebito) {
      return widget.total * (1 + (widget.taxaDebito / 100));
    } else {
      if (_parcelas == 1) {
        return widget.total * (1 + (widget.taxaCreditoVista / 100));
      } else {
        double taxa = widget.taxasParcelado[_parcelas.toString()] ?? 0.0;
        return widget.total * (1 + (taxa / 100));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final real = NumberFormat.currency(locale: 'pt_BR', symbol: 'R\$');
    return AlertDialog(
      backgroundColor: Colors.grey[900],
      content: SizedBox(
        width: 700, height: 500,
        child: Row(
          children: [
            SizedBox(width: 180, child: Column(children: [_btnMetodo("DINHEIRO", Icons.money), _btnMetodo("CARTÃO", Icons.credit_card), _btnMetodo("PIX", Icons.qr_code)])),
            const VerticalDivider(color: Colors.grey),
            Expanded(child: Padding(padding: const EdgeInsets.only(left: 20.0), child: _conteudoPagamento(real))),
          ],
        ),
      ),
    );
  }

  Widget _btnMetodo(String nome, IconData icon) {
    bool selecionado = _metodo == nome;
    return Padding(padding: const EdgeInsets.only(bottom: 10), child: ElevatedButton.icon(icon: Icon(icon), label: Text(nome), style: ElevatedButton.styleFrom(backgroundColor: selecionado ? Colors.green : Colors.grey[800], minimumSize: const Size(double.infinity, 60)), onPressed: () => setState(() { _metodo = nome; if(nome == 'DINHEIRO') _focoDinheiro.requestFocus(); })));
  }

  Widget _conteudoPagamento(NumberFormat real) {
    if (_metodo == 'DINHEIRO') {
      return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Text("Total: ${real.format(widget.total)}", style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold)), const SizedBox(height: 30),
        TextField(controller: _recebidoController, focusNode: _focoDinheiro, keyboardType: TextInputType.number, style: const TextStyle(fontSize: 40), decoration: const InputDecoration(labelText: "Valor Recebido", border: OutlineInputBorder(), prefixText: "R\$ "), onChanged: _calcularTroco, onSubmitted: (v) { if (_troco >= 0) widget.onFinalizar('DINHEIRO', _valorRecebidoDinheiro); }),
        const SizedBox(height: 20), Text(_troco >= 0 ? "TROCO: ${real.format(_troco)}" : "FALTA: ${real.format(_troco.abs())}", style: TextStyle(color: _troco >= 0 ? Colors.green : Colors.red, fontSize: 30, fontWeight: FontWeight.bold)), const Spacer(),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.green, minimumSize: const Size(double.infinity, 60)), onPressed: _troco >= 0 ? () => widget.onFinalizar('DINHEIRO', _valorRecebidoDinheiro) : null, child: const Text("CONFIRMAR (ENTER)", style: TextStyle(color: Colors.white, fontSize: 20)))
      ]);
    } else if (_metodo == 'PIX') {
      return Column(children: [Container(color: Colors.white, padding: const EdgeInsets.all(10), child: QrImageView(data: MINHA_CHAVE_PIX, size: 180)), const SizedBox(height: 10), Text(real.format(widget.total), style: const TextStyle(color: Colors.greenAccent, fontSize: 30, fontWeight: FontWeight.bold)), const Spacer(), ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.green, minimumSize: const Size(double.infinity, 60)), onPressed: () => widget.onFinalizar('PIX', widget.total), child: const Text("JÁ RECEBI", style: TextStyle(color: Colors.white, fontSize: 20)))]);
    } else {
      final totalComTaxa = _calcularTotalCartao();
      final diferenca = totalComTaxa - widget.total;
      return Column(mainAxisAlignment: MainAxisAlignment.start, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [Expanded(child: ChoiceChip(label: const Center(child: Padding(padding: EdgeInsets.all(12), child: Text("DÉBITO"))), selected: _isDebito, onSelected: (v) => setState(() { _isDebito = true; _parcelas = 1; }), selectedColor: Colors.blue)), const SizedBox(width: 10), Expanded(child: ChoiceChip(label: const Center(child: Padding(padding: EdgeInsets.all(12), child: Text("CRÉDITO"))), selected: !_isDebito, onSelected: (v) => setState(() { _isDebito = false; }), selectedColor: Colors.deepPurple))]), const SizedBox(height: 20),
        if (!_isDebito) ...[DropdownButtonFormField<int>(value: _parcelas, decoration: const InputDecoration(labelText: "Parcelamento", border: OutlineInputBorder()), items: List.generate(12, (index) => index + 1).map((p) { double taxa = (p == 1) ? widget.taxaCreditoVista : (widget.taxasParcelado[p.toString()] ?? 0); double valTotal = widget.total * (1 + taxa/100); return DropdownMenuItem(value: p, child: Text("${p}x de ${real.format(valTotal / p)} (Total: ${real.format(valTotal)})")); }).toList(), onChanged: (v) => setState(() => _parcelas = v!)), const SizedBox(height: 20)],
          Container(padding: const EdgeInsets.all(15), decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(10)), child: Column(children: [Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text("Valor Original:"), Text(real.format(widget.total))]), const SizedBox(height: 5), Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text("Taxa Maquininha:"), Text("+ ${real.format(diferenca)}", style: const TextStyle(color: Colors.orange))]), const Divider(), Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text("A COBRAR:", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)), Text(real.format(totalComTaxa), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.greenAccent))])])), const Spacer(),
          ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.blue, minimumSize: const Size(double.infinity, 60)), onPressed: () { String desc = _isDebito ? "DÉBITO" : "CRÉDITO ${_parcelas}x"; widget.onFinalizar(desc, totalComTaxa); }, child: const Text("COBRAR NA MÁQUINA", style: TextStyle(color: Colors.white, fontSize: 20)))
      ]);
    }
  }
}
