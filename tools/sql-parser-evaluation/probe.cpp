#include "antlr4-runtime.h"
#include "MySQLLexer.h"
#include "MySQLParser.h"
#include "SqlModes.h"
#include <chrono>
#include <iomanip>
#include <iostream>
#include <sstream>

static std::string quote(const std::string &value) {
    std::ostringstream out; out << '"';
    for (unsigned char c : value) {
        if (c == '"' || c == '\\') out << '\\' << c;
        else if (c < 32) out << "\\u" << std::hex << std::setw(4) << std::setfill('0') << unsigned(c);
        else out << c;
    }
    return out.str() + '"';
}
struct Errors : antlr4::BaseErrorListener {
    std::vector<std::string> messages;
    void syntaxError(antlr4::Recognizer *, antlr4::Token *, size_t line, size_t col,
                     const std::string &message, std::exception_ptr) override {
        messages.push_back(std::to_string(line) + ":" + std::to_string(col) + " " + message);
    }
};
// ANTLR indexes Unicode code points. Convert them to UTF-8 byte offsets.
static std::vector<size_t> offsets(const std::string &text) {
    std::vector<size_t> result;
    for (size_t i = 0; i < text.size(); ++i)
        if ((static_cast<unsigned char>(text[i]) & 0xc0) != 0x80) result.push_back(i);
    result.push_back(text.size()); return result;
}
static void spans(antlr4::tree::ParseTree *tree, MySQLParser &parser,
                  const std::string &sql, const std::vector<size_t> &map,
                  std::vector<std::string> &result) {
    if (auto *ctx = dynamic_cast<antlr4::ParserRuleContext *>(tree)) {
        const auto &name = parser.getRuleNames()[ctx->getRuleIndex()];
        if (name == "tableRef" || name == "tableName" || name == "alterListItem" ||
            name == "fieldDefinition" || name == "exprWithParentheses" || name == "charsetName") {
            auto *first = ctx->getStart(); auto *last = ctx->getStop();
            if (first && last && first->getStartIndex() < map.size() && last->getStopIndex()+1 < map.size()) {
                size_t a = map[first->getStartIndex()], b = map[last->getStopIndex()+1];
                if (b >= a) result.push_back("{\"rule\":"+quote(name)+",\"start\":"+std::to_string(a)+
                    ",\"end\":"+std::to_string(b)+",\"text\":"+quote(sql.substr(a,b-a))+"}");
            }
        }
    }
    for (auto *child : tree->children) spans(child, parser, sql, map, result);
}
static std::string array(const std::vector<std::string> &values, bool strings) {
    std::string out="[";
    for (size_t i=0; i<values.size(); ++i) { if (i) out+=","; out+=strings?quote(values[i]):values[i]; }
    return out+"]";
}
int main() {
    std::string line;
    while (std::getline(std::cin,line)) {
        std::istringstream input(line); std::string id, version, mode, hex;
        std::getline(input,id,'\t'); std::getline(input,version,'\t');
        std::getline(input,mode,'\t'); std::getline(input,hex,'\t');
        std::string sql;
        for (size_t i=0;i+1<hex.size();i+=2) sql+=static_cast<char>(std::stoul(hex.substr(i,2),nullptr,16));
        Errors errors; std::vector<std::string> selected;
        bool eof=false, tokenSpans=true; size_t count=0; std::string modeTree;
        auto start=std::chrono::steady_clock::now();
        try {
            antlr4::ANTLRInputStream chars(sql); MySQLLexer lexer(&chars);
            lexer.serverVersion=std::stoi(version); lexer.sqlModes=SqlModes::sqlModeFromString(mode);
            lexer.supportMle=false; lexer.charSets={"_utf8","_utf8mb3","_utf8mb4","_latin1","_binary","_sjis","_gbk"};
            lexer.removeErrorListeners(); lexer.addErrorListener(&errors);
            antlr4::CommonTokenStream tokens(&lexer); tokens.fill(); count=tokens.size();
            auto map=offsets(sql);
            for (auto *t:tokens.getTokens()) {
                if (t->getType()==antlr4::Token::EOF) continue;
                size_t a=t->getStartIndex(), b=t->getStopIndex()+1;
                if (a>=map.size() || b>=map.size() || b<a || sql.substr(map[a],map[b]-map[a])!=t->getText()) tokenSpans=false;
            }
            MySQLParser parser(&tokens); parser.serverVersion=lexer.serverVersion;
            parser.sqlModes=lexer.sqlModes; parser.supportMle=false;
            parser.removeErrorListeners(); parser.addErrorListener(&errors);
            auto *tree=parser.simpleStatement();
            if (tokens.LA(1)==MySQLLexer::SEMICOLON_SYMBOL) tokens.consume();
            eof=tokens.LA(1)==antlr4::Token::EOF;
            if (!eof) errors.messages.push_back("unconsumed input");
            if (errors.messages.empty()) spans(tree,parser,sql,map,selected);
            if (id.rfind("mode-",0)==0 && errors.messages.empty()) modeTree=tree->toStringTree(&parser);
        } catch (const std::exception &e) { errors.messages.push_back(e.what()); }
        double ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
        std::cout<<"{\"id\":"<<quote(id)<<",\"accepted\":"<<(errors.messages.empty()&&eof?"true":"false")
                 <<",\"ms\":"<<ms<<",\"tokens\":"<<count<<",\"tokenSpans\":"<<(tokenSpans?"true":"false")
                 <<",\"errors\":"<<array(errors.messages,true)<<",\"spans\":"<<array(selected,false)
                 <<",\"modeTree\":"<<quote(modeTree)<<"}"<<std::endl;
    }
}
